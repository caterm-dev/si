"""Small synthetic checks for new-data weight initialization and exact continuation."""

import contextlib
import io
import math
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import torch

from llm.reranker_large.corpus_data import prepare_corpus
from llm.reranker_large.export import export
from llm.reranker_large.scripts import continue_pretrain as continuation
from llm.reranker_large.scripts.prepare_extra_data import prepare
from llm.reranker_large.settings import code_identity, file_hash, fingerprint, read_json, write_json
from llm.reranker_large.tests.test_corpus import fixture
from llm.reranker_large.train import train as train_parent
from llm.reranker_large.fixtures import SyntheticTeacher
from llm.reranker_large.prepare import prepare_pools
from llm.reranker_large.teacher import cache_teacher
from llm.pinyin_to_text.common import read_jsonl, write_jsonl


class ContinuationTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix='si-continuation-test-')
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.config, mixture, raw, notices = fixture(self.root/'input')
        value = read_json(self.config)
        value['training'].update(batch_size=1, gradient_accumulation=2, max_steps=100,
                                 schedule_steps=100, validate_every=1, save_every=1, warmup_steps=1)
        write_json(self.config, value)
        self.parent_data, self.data = self.root/'parent-data', self.root/'new-data'
        self.parent_run = self.root/'parent-run'
        with contextlib.redirect_stdout(io.StringIO()):
            prepare_corpus(self.config, mixture, raw, notices, self.parent_data)
            train_parent(self.config, self.parent_data, self.parent_run, 'cpu', max_steps=1, threads=1)
            prepare(self.config, mixture, raw, notices, self.parent_data, self.data, train_tokens=50)
        self.parent = self.parent_run/'last.pt'
        self.parent_hash = file_hash(self.parent)
        value['training']['single_pass'] = True
        self.config = self.root/'continuation.json'
        write_json(self.config, value)

    def run_train(self, name, **kwargs):
        resume = kwargs.get('resume', False)
        with contextlib.redirect_stdout(io.StringIO()):
            return continuation.train(self.config, self.data, self.root/name,
                None if resume else self.parent, device_name='cpu', threads=1, **kwargs)

    def test_check_only_is_read_only_and_old_trainer_identity_unchanged(self):
        identity = code_identity()
        result = self.run_train('check', check_only=True)
        windows = read_json(self.data/'manifest.json')['splits']['train']['windows']
        self.assertEqual(result['one_pass_steps'], math.ceil(windows/2))
        self.assertFalse(result['training_started'])
        self.assertFalse((self.root/'check').exists())
        self.assertEqual(result['initial_checkpoint']['step'], 1)
        self.assertEqual(file_hash(self.parent), self.parent_hash)
        self.assertEqual(code_identity(), identity)

    def test_initial_weights_are_identical_but_optimizer_and_counters_are_fresh(self):
        parent = torch.load(self.parent, weights_only=True)
        self.assertTrue(parent['optimizer']['state'])
        saved = []
        actual_save = continuation.atomic_checkpoint

        def capture(path, value):
            if not saved:
                self.assertEqual(value['step'], 0)
                self.assertEqual(value['tokens_seen'], 0)
                self.assertFalse(value['optimizer']['state'])
                for key, tensor in parent['model'].items():
                    self.assertTrue(torch.equal(tensor, value['model'][key]))
            saved.append(path.name)
            actual_save(path, value)

        with mock.patch.object(continuation, 'atomic_checkpoint', side_effect=capture):
            self.run_train('fresh', max_steps=1)
        checkpoint = torch.load(self.root/'fresh/last.pt', weights_only=True)
        self.assertEqual(checkpoint['initial_checkpoint']['sha256'], self.parent_hash)
        self.assertEqual(checkpoint['step'], 1)
        self.assertEqual(checkpoint['dataset_id'], read_json(self.data/'manifest.json')['dataset_id'])
        self.assertEqual(file_hash(self.parent), self.parent_hash)

    def test_single_pass_resume_is_bitwise_and_exports_with_lineage(self):
        target = self.data/'test.tokens.bin'
        hidden = target.with_suffix('.hidden')
        target.rename(hidden)
        try:
            self.run_train('resumed', max_steps=1)
            self.run_train('resumed', resume=True, max_steps=100)
            result = self.run_train('whole')
        finally:
            hidden.rename(target)
        full = torch.load(self.root/'whole/last.pt', weights_only=True)
        resumed = torch.load(self.root/'resumed/last.pt', weights_only=True)
        manifest = read_json(self.data/'manifest.json')
        self.assertTrue(result['pass_complete'])
        self.assertEqual(result['tokens_seen'], manifest['splits']['train']['targets'])
        self.assertEqual(full['cursor'], manifest['splits']['train']['windows'])
        self.assertEqual(full['epoch'], 0)
        for key, tensor in full['model'].items():
            self.assertTrue(torch.equal(tensor, resumed['model'][key]), key)
        self.assertEqual(full['lineage_dataset_ids'], sorted([manifest['dataset_id'], manifest['parent_dataset_id']]))
        exported = export(self.root/'whole/best.pt', self.data, self.root/'export')
        self.assertEqual(exported['initial_checkpoint']['sha256'], self.parent_hash)
        self.assertEqual(exported['stage'], 'pretrain')
        with self.assertRaisesRegex(ValueError, 'budget'):
            self.run_train('whole', resume=True, max_steps=1000)

    def test_ancestor_exclusion_and_tokenizer_mismatches_are_rejected_atomically(self):
        manifest = read_json(self.data/'manifest.json')
        original = (self.data/'manifest.json').read_bytes()
        manifest['excluded_dataset_ids'] = []
        manifest.pop('dataset_id')
        manifest['dataset_id'] = fingerprint(manifest)
        write_json(self.data/'manifest.json', manifest)
        with self.assertRaisesRegex(ValueError, 'exclude every ancestor'):
            self.run_train('bad-lineage')
        self.assertFalse((self.root/'bad-lineage').exists())
        (self.data/'manifest.json').write_bytes(original)
        parent = torch.load(self.parent, weights_only=True)
        parent['tokenizer_digest'] = 'invalid'
        bad = self.root/'bad-parent.pt'
        torch.save(parent, bad)
        with self.assertRaisesRegex(ValueError, 'frozen tokenizer'):
            continuation.train(self.config, self.data, self.root/'bad-tokenizer', bad,
                               device_name='cpu', threads=1)
        self.assertFalse((self.root/'bad-tokenizer').exists())

    def test_existing_run_and_changed_resume_config_are_rejected(self):
        self.run_train('partial', max_steps=1)
        pin = file_hash(self.root/'partial/last.pt')
        with self.assertRaises(FileExistsError):
            self.run_train('partial')
        config = read_json(self.config)
        config['training']['learning_rate'] *= 2
        write_json(self.config, config)
        with self.assertRaisesRegex(ValueError, 'Resume requires'):
            self.run_train('partial', resume=True, max_steps=100)
        self.assertEqual(file_hash(self.root/'partial/last.pt'), pin)

    def test_export_style_ancestor_metadata_cannot_bypass_exclusions(self):
        parent = torch.load(self.parent, weights_only=True)
        parent['initial_checkpoint'] = dict(dataset_id='older-parent', ancestor_dataset_ids=['oldest-parent'])
        parent.pop('lineage_dataset_ids', None)
        path = self.root/'ancestor-parent.pt'
        torch.save(parent, path)
        with self.assertRaisesRegex(ValueError, 'exclude every ancestor'):
            continuation.train(self.config, self.data, self.root/'bad-ancestor', path,
                               device_name='cpu', threads=1)
        self.assertFalse((self.root/'bad-ancestor').exists())

    def distillation_inputs(self):
        self.run_train('continued-for-kd', max_steps=1)
        config = read_json(self.config)
        config['stage'] = 'distill'
        config['training'].pop('single_pass')
        config['training'].update(max_steps=2, schedule_steps=8)
        kd = self.root/'distill.json'
        write_json(kd, config)
        records = []
        for split in ('train', 'validation', 'test'):
            doc = next(read_jsonl(self.parent_data/f'{split}.documents.jsonl'))
            start = next(i for i, c in enumerate(doc['text']) if '\u4e00' <= c <= '\u9fff')
            observed = doc['text'][start]
            records.append(dict(id=split, document_id=doc['id'], input='authored-' + split,
                context=doc['text'][:start], observed_text=observed,
                candidates=[dict(text=observed, language='zh-Hans'),
                            dict(text='你' if observed != '你' else '好', language='zh-Hans')]))
        write_jsonl(self.root/'records.jsonl', records)
        write_json(self.root/'provenance.json', dict(schema_version=1, sources=[dict(
            id='fixture', origin='SI-authored synthetic test data', revision='v1', license='GPL-3.0-only')]))
        prepare_pools(kd, self.parent_data, self.root/'records.jsonl', self.root/'provenance.json', self.root/'pools')
        cache_teacher(kd, self.parent_data, self.root/'pools', self.root/'teacher', SyntheticTeacher())
        return kd, self.root/'continued-for-kd/last.pt'

    def test_continued_weights_initialize_old_candidate_cache_and_resume_exactly(self):
        with contextlib.redirect_stdout(io.StringIO()):
            kd, continued = self.distillation_inputs()
            pin = file_hash(continued)
            common = dict(pools_path=self.root/'teacher', threads=1)
            result = train_parent(kd, self.parent_data, self.root/'check-kd', 'cpu',
                init_checkpoint=continued, init_data=self.data, check_only=True, **common)
            self.assertFalse(result['training_started'])
            self.assertFalse((self.root/'check-kd').exists())
            continued_state = torch.load(continued, weights_only=True)
            from llm.reranker_small.runtime import atomic_checkpoint
            def capture(path, payload):
                if payload['step'] == 0:
                    self.assertFalse(payload['optimizer']['state'])
                    for key in payload['model']:
                        self.assertTrue(torch.equal(payload['model'][key], continued_state['model'][key]))
                atomic_checkpoint(path, payload)
            with mock.patch('llm.reranker_large.train.atomic_checkpoint', side_effect=capture):
                train_parent(kd, self.parent_data, self.root/'kd-full', 'cpu',
                    init_checkpoint=continued, init_data=self.data, **common)
            train_parent(kd, self.parent_data, self.root/'kd-resumed', 'cpu',
                init_checkpoint=continued, init_data=self.data, max_steps=1, **common)
            train_parent(kd, self.parent_data, self.root/'kd-resumed', 'cpu', resume=True, **common)
        full = torch.load(self.root/'kd-full/last.pt', weights_only=True)
        resumed = torch.load(self.root/'kd-resumed/last.pt', weights_only=True)
        for key in full['model']:
            self.assertTrue(torch.equal(full['model'][key], resumed['model'][key]), key)
        self.assertEqual(full['initial_checkpoint'], resumed['initial_checkpoint'])
        self.assertEqual(full['dataset_id'], read_json(self.parent_data/'manifest.json')['dataset_id'])
        self.assertEqual(full['initial_checkpoint']['source_dataset_manifest'], read_json(self.data/'manifest.json'))
        self.assertEqual(full['initial_checkpoint']['sha256'], pin)
        self.assertEqual(file_hash(continued), pin)
        exported = export(self.root/'kd-full/last.pt', self.parent_data, self.root/'kd-export', self.root/'teacher')
        self.assertEqual(exported['initial_checkpoint'], full['initial_checkpoint'])

    def test_continued_initialization_rejects_missing_wrong_or_unrelated_source(self):
        with contextlib.redirect_stdout(io.StringIO()):
            kd, continued = self.distillation_inputs()
            common = dict(pools_path=self.root/'teacher', init_checkpoint=continued, check_only=True, threads=1)
            with self.assertRaisesRegex(ValueError, '--init-data'):
                train_parent(kd, self.parent_data, self.root/'missing-source', 'cpu', **common)
            with self.assertRaisesRegex(ValueError, 'recorded continuation'):
                train_parent(kd, self.parent_data, self.root/'wrong-source', 'cpu', init_data=self.parent_data, **common)
            payload = torch.load(continued, weights_only=True)
            payload['lineage_dataset_ids'] = [payload['dataset_id'], 'unrelated']
            torch.save(payload, self.root/'unrelated.pt')
            common['init_checkpoint'] = self.root/'unrelated.pt'
            with self.assertRaisesRegex(ValueError, 'recorded continuation'):
                train_parent(kd, self.parent_data, self.root/'unrelated', 'cpu', init_data=self.data, **common)
            common['init_checkpoint'] = continued
            tokenizer = self.data/'tokenizer.json'
            tokenizer.write_bytes(tokenizer.read_bytes() + b'\n')
            with self.assertRaisesRegex(ValueError, 'modified'):
                train_parent(kd, self.parent_data, self.root/'changed-tokenizer', 'cpu', init_data=self.data, **common)
            for name in ('missing-source', 'wrong-source', 'unrelated', 'changed-tokenizer'):
                self.assertFalse((self.root/name).exists())


if __name__ == '__main__':
    unittest.main()
