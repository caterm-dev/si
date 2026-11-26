import contextlib
import io
import math
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest

import torch

from llm.pinyin_to_text.common import normalized, read_jsonl, write_jsonl
from llm.export_rust import export as export_rust
from llm.reranker_small.data import load_bundle
from llm.reranker_small.model import CharacterLM, parameter_report
from llm.reranker_small.runtime import atomic_checkpoint, load_checkpoint, rank_candidates
from llm.reranker_small.tokenizer import Tokenizer
from llm.reranker_large.data import load_pools
from llm.reranker_large.evaluate import evaluate, rust_check
from llm.reranker_large.export import export
from llm.reranker_large.fixtures import SyntheticTeacher, fixture
from llm.reranker_large.prepare import prepare_documents, prepare_pools
from llm.reranker_large.scoring import distillation_loss, forward_pool, suffix, validate_pool
from llm.reranker_large.settings import ROOT, file_hash, fingerprint, load_config, read_json, write_json
from llm.reranker_large.teacher import QwenTeacher, cache_teacher
from llm.reranker_large.train import train


class ArchitectureTests(unittest.TestCase):
    def test_script_help_and_shell_syntax_from_another_directory(self):
        for path in sorted((ROOT / 'scripts').glob('*.sh')):
            subprocess.run(['bash', '-n', str(path)], check=True, capture_output=True)
            if path.name not in ('common.sh', 'check.sh'):
                result = subprocess.run([str(path), '--help'], cwd='/tmp', capture_output=True, text=True, timeout=20)
                self.assertEqual(result.returncode, 0, (path.name, result.stderr))

    def test_teacher_scores_first_candidate_token_without_context_eos_or_normalization(self):
        class FixedModel:
            config = SimpleNamespace(bos_token_id=0, eos_token_id=0, max_position_embeddings=64)

            def __call__(self, input_ids, attention_mask, use_cache):
                assert not use_cache
                probabilities = torch.tensor([1., 2., 3., 4.]).log()
                return SimpleNamespace(logits=probabilities.expand(*input_ids.shape, 4))

        teacher = QwenTeacher.__new__(QwenTeacher)
        teacher.device = torch.device('cpu')
        teacher.model = FixedModel()
        teacher.tokenizer = SimpleNamespace(encode=lambda text, **_: [{'c': 1, 'x': 2, 'y': 3}[c] for c in text])
        values = teacher.score(dict(context='cc', candidates=[dict(text='x'), dict(text='yy')]))
        self.assertAlmostEqual(values[0], math.log(.3), places=6)
        self.assertAlmostEqual(values[1], 2 * math.log(.4), places=6)

    def test_production_parameter_count_and_rust_dimensions(self):
        config = load_config(ROOT / 'configs/pretrain.json')
        self.assertEqual(parameter_report(config['model'])['parameters'], 15592320)
        with torch.device('meta'):
            model = CharacterLM(config['model'])
        self.assertIs(model.output.weight, model.embedding.weight)
        self.assertEqual(config['model']['width'] // config['model']['heads'], 64)

    def test_full_size_random_initialization_exports_and_matches_rust_without_training(self):
        binary = ROOT.parents[1] / 'target/release/si-neural'
        if not binary.is_file():
            self.skipTest('Build Release si-neural for full-architecture parity')
        config = load_config(ROOT / 'configs/pretrain.json')
        torch.set_num_threads(2)
        torch.manual_seed(8)
        tokenizer = Tokenizer(8192, list(dict.fromkeys('今天下午我们一起开会慧你好您先写下行得通')))
        model = CharacterLM(config['model'], tokenizer.active_ids).eval()
        with tempfile.TemporaryDirectory(prefix='si-untrained-shape-') as directory:
            root = Path(directory)
            checkpoint = root / 'untrained.pt'
            atomic_checkpoint(checkpoint, dict(schema_version=1, kind='si-character-lm',
                config=config, tokenizer=tokenizer.to_dict(), tokenizer_digest=tokenizer.digest,
                model=model.state_dict(), dataset_id='synthetic-random-initialization-only', step=0))
            export_rust('reranker', checkpoint, root / 'rust')
            report = rust_check(checkpoint, root / 'rust', binary, root / 'parity.json', repeats=2, threads=2)
            self.assertEqual(report['parity_queries'], 4)

    def test_listwise_loss_is_order_invariant_and_teacher_is_detached(self):
        settings = dict(temperature=2., kd_weight=1., lm_weight=.2, label_weight=.3)
        scores = torch.tensor([-1., -2., -4.], requires_grad=True)
        teacher = torch.tensor([-2., -1., -5.], requires_grad=True)
        observed = torch.tensor(1.5, requires_grad=True)
        loss, _ = distillation_loss(scores, teacher, observed, settings, [0, 1])
        perm = [2, 0, 1]
        other, _ = distillation_loss(scores[perm], teacher[perm], observed, settings, [1, 2])
        self.assertAlmostEqual(float(loss.detach()), float(other.detach()), places=6)
        loss.backward()
        self.assertTrue(torch.isfinite(scores.grad).all())
        self.assertIsNone(teacher.grad)
        self.assertAlmostEqual(float(observed.grad), .2, places=6)
        zero, kl = distillation_loss(scores.detach(), scores.detach(), torch.tensor(0.), settings)
        self.assertAlmostEqual(float(kl), 0., places=6)

    def test_source_scalar_boundaries_and_production_pool_abstention(self):
        tokenizer = Tokenizer(512, ['你', '好'])
        self.assertEqual(suffix('你🙂好', tokenizer, 4), '好')
        config = load_config(ROOT / 'configs/smoke.json')
        row = dict(context='', observed_text='你好', candidates=[dict(text='你好', language='zh-Hans'),
                                                               dict(text='你好', language='mixed')])
        self.assertTrue(validate_pool(row, tokenizer, config))
        row['candidates'][1]['language'] = 'zh-Hans'
        with self.assertRaisesRegex(ValueError, 'Duplicate'):
            validate_pool(row, tokenizer, config)
        row['candidates'][1] = dict(text='🙂🙂🙂', language='mixed')
        self.assertFalse(validate_pool(row, tokenizer, config))


class WorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix='si-large-tests-')
        cls.root = Path(cls.temporary.name)
        cls.pre, cls.kd, cls.provenance, cls.documents, cls.records = fixture(cls.root / 'inputs')
        cls.lm, cls.pools, cls.teacher = (cls.root / name for name in ('lm', 'pools', 'teacher'))
        prepare_documents(cls.pre, cls.documents, cls.provenance, cls.lm)
        prepare_pools(cls.pre, cls.lm, cls.records, cls.provenance, cls.pools)
        cls.fake = SyntheticTeacher()
        cache_teacher(cls.pre, cls.lm, cls.pools, cls.teacher, cls.fake)
        with contextlib.redirect_stdout(io.StringIO()):
            train(cls.pre, cls.lm, cls.root / 'pretrain', 'cpu', max_steps=4, threads=2)
            train(cls.pre, cls.lm, cls.root / 'pre-resume', 'cpu', max_steps=1, threads=2)
            train(cls.pre, cls.lm, cls.root / 'pre-resume', 'cpu', resume=True, max_steps=4, threads=2)
            for run, steps in [('distill', 4), ('kd-resume', 1)]:
                train(cls.kd, cls.lm, cls.root / run, 'cpu', pools_path=cls.teacher,
                      init_checkpoint=cls.root / 'pretrain/best.pt', max_steps=steps, threads=2)
            train(cls.kd, cls.lm, cls.root / 'kd-resume', 'cpu', pools_path=cls.teacher,
                  resume=True, max_steps=4, threads=2)

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def test_exact_cpu_resume_in_both_phases(self):
        for full, resumed in [('pretrain', 'pre-resume'), ('distill', 'kd-resume')]:
            a = torch.load(self.root / full / 'last.pt', weights_only=True)
            b = torch.load(self.root / resumed / 'last.pt', weights_only=True)
            self.assertEqual((a['cursor'], a['epoch'], a['tokens_seen']), (b['cursor'], b['epoch'], b['tokens_seen']))
            self.assertTrue(torch.equal(a['torch_rng'], b['torch_rng']))
            for name in a['model']:
                self.assertTrue(torch.equal(a['model'][name], b['model'][name]), name)

    def test_teacher_never_scores_final_test_and_cache_preserves_identity(self):
        self.assertNotIn('test', self.fake.calls)
        self.assertEqual(file_hash(self.teacher / 'test.jsonl'), file_hash(self.pools / 'test.jsonl'))
        manifest, tokenizer, _ = load_bundle(self.lm, load_config(self.pre), ('train',))
        _, pools = load_pools(self.teacher, load_config(self.pre), manifest, tokenizer, ('train',), scored=True)
        self.assertEqual(pools['train'][0]['candidates'][0]['text'], pools['train'][0]['candidates'][2]['text'])
        self.assertNotEqual(pools['train'][0]['candidates'][0]['language'], pools['train'][0]['candidates'][2]['language'])

    def test_student_training_scores_match_inference_mean_scores(self):
        checkpoint, model, tokenizer = load_checkpoint(self.root / 'distill/last.pt', torch.device('cpu'))
        manifest, _, _ = load_bundle(self.lm, checkpoint['config'], ('train',))
        _, data = load_pools(self.teacher, checkpoint['config'], manifest, tokenizer, ('train',), scored=True)
        row = data['train'][0]
        with torch.no_grad():
            actual, _ = forward_pool(model, tokenizer, row, torch.device('cpu'), checkpoint['config']['scoring'])
        expected = rank_candidates(model, tokenizer, row['context'], [c['text'] for c in row['candidates']],
                                   torch.device('cpu'), length_penalty=1.)
        for a, b in zip(actual.tolist(), expected['scores'], strict=True):
            self.assertAlmostEqual(a, b, places=5)

    def test_split_conflicts_and_unknown_parent_are_atomic(self):
        rows = list(read_jsonl(self.documents))
        rows[1]['group'] = rows[0]['group']
        path = self.root / 'bad-documents.jsonl'
        write_jsonl(path, rows)
        with self.assertRaisesRegex(ValueError, 'group crosses'):
            prepare_documents(self.pre, path, self.provenance, self.root / 'bad-docs')
        self.assertFalse((self.root / 'bad-docs').exists())
        records = list(read_jsonl(self.records))
        records[0]['document_id'] = 'unrelated-document'
        path = self.root / 'bad-pools.jsonl'
        write_jsonl(path, records)
        with self.assertRaisesRegex(ValueError, 'absent'):
            prepare_pools(self.pre, self.lm, path, self.provenance, self.root / 'bad-pools')
        self.assertFalse((self.root / 'bad-pools').exists())

    def test_unobserved_span_is_not_accepted_as_auxiliary_training_text(self):
        records = list(read_jsonl(self.records))
        records[0]['observed_text'] = '完全虚构'
        path = self.root / 'unobserved-pools.jsonl'
        write_jsonl(path, records)
        with self.assertRaisesRegex(ValueError, 'contiguous'):
            prepare_pools(self.pre, self.lm, path, self.provenance, self.root / 'unobserved')
        self.assertFalse((self.root / 'unobserved').exists())

    def test_byte_fallback_excludes_and_counts_the_entire_pool(self):
        records = list(read_jsonl(self.records))
        records[0]['candidates'][1]['text'] = '🙂🙂🙂'
        path = self.root / 'oversized-pools.jsonl'
        write_jsonl(path, records)
        result = prepare_pools(self.pre, self.lm, path, self.provenance, self.root / 'oversized')
        self.assertEqual(result['exclusions']['train_unscorable_token_limit'], 1)
        self.assertEqual(result['splits']['train']['pools'], 1)

    def test_reordered_equivalent_queries_cannot_cross_source_splits(self):
        documents = list(read_jsonl(self.documents))
        documents[1]['text'] = documents[1]['text'].replace('账号需要登陆', '今天需要登录')
        doc_path = self.root / 'query-documents.jsonl'
        write_jsonl(doc_path, documents)
        lm = self.root / 'query-lm'
        prepare_documents(self.pre, doc_path, self.provenance, lm)
        rows = list(read_jsonl(self.records))
        for row in rows:
            if row['id'].startswith('validation'):
                row['document_id'] = fingerprint(normalized(documents[1]['text']))
        rows[2].update(context='今天需要', observed_text='登录', reference_indices=[])
        rows[2]['candidates'].reverse()
        path = self.root / 'query-pools.jsonl'
        write_jsonl(path, rows)
        with self.assertRaisesRegex(ValueError, 'query crosses'):
            prepare_pools(self.pre, lm, path, self.provenance, self.root / 'query-pools')
        self.assertFalse((self.root / 'query-pools').exists())

    def test_config_change_and_teacher_corruption_cannot_resume(self):
        before = file_hash(self.root / 'kd-resume/last.pt')
        config = read_json(self.kd)
        config['distillation']['temperature'] = 3.
        other = self.root / 'changed-config.json'
        write_json(other, config)
        with self.assertRaisesRegex(ValueError, 'Resume requires'):
            train(other, self.lm, self.root / 'kd-resume', 'cpu', pools_path=self.teacher,
                  resume=True, max_steps=5, threads=2)
        target = self.teacher / 'train.jsonl'
        original = target.read_bytes()
        try:
            target.write_bytes(original + b'\n')
            with self.assertRaisesRegex(ValueError, 'modified'):
                train(self.kd, self.lm, self.root / 'kd-resume', 'cpu', pools_path=self.teacher,
                      resume=True, max_steps=5, threads=2)
        finally:
            target.write_bytes(original)
        self.assertEqual(before, file_hash(self.root / 'kd-resume/last.pt'))

    def test_evaluation_export_and_optional_rust_parity(self):
        output = self.root / 'evaluation.json'
        report = evaluate(self.root / 'distill/best.pt', self.lm, self.pools, output,
                          split='test', device_name='cpu', threads=2)
        self.assertEqual(report['counts']['queries'], 2)
        self.assertIsNone(report['teacher_agreement'])
        destination = self.root / 'export'
        manifest = export(self.root / 'distill/best.pt', self.lm, destination, self.teacher)
        self.assertEqual(manifest['teacher']['model_id'], self.fake.identity['model_id'])
        self.assertTrue((destination / 'metadata/pretraining/source-lock.json').is_file())
        self.assertTrue((destination / 'metadata/distillation/manifest.json').is_file())
        with self.assertRaises(FileExistsError):
            export(self.root / 'distill/best.pt', self.lm, destination, self.teacher)
        binary = ROOT.parents[1] / 'target/release/si-neural'
        if binary.is_file():
            parity = rust_check(self.root / 'distill/best.pt', destination / 'rust', binary,
                                self.root / 'parity.json', repeats=2, threads=2)
            self.assertEqual(parity['parity_queries'], 4)

    def test_tokenizer_fits_train_only_and_final_test_is_not_opened_by_training(self):
        config = load_config(self.pre)
        _, tokenizer, _ = load_bundle(self.lm, config, ('train',))
        self.assertNotIn('账', tokenizer.lookup)
        target = self.lm / 'test.tokens.bin'
        hidden = target.with_suffix('.hidden')
        target.rename(hidden)
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                train(self.pre, self.lm, self.root / 'without-test', 'cpu', max_steps=1, threads=2)
        finally:
            hidden.rename(target)


if __name__ == '__main__':
    unittest.main()
