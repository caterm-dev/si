import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest

import torch

from llm.reranker_small.benchmarks.build import (
    HERE, Matcher, anchors, assign_families, audit_overlap, check_readings, diagnostics, make_cases, split_for, validate,
)
from llm.reranker_small.benchmarks.evaluate import evaluate_suite, load_suite, summarize
from llm.reranker_small.model import CharacterLM
from llm.reranker_small.settings import REPO, file_hash, fingerprint, read_json, write_json
from llm.reranker_small.tokenizer import Tokenizer


class BenchmarkTests(unittest.TestCase):
    def test_shared_word_contrasts_and_wrapped_sentences_remain_in_one_family(self):
        rows = [{'input': 'quanli', 'candidates': ['权利', '权力']},
                {'input': 'baohuquanli', 'candidates': ['保护权利', '保护权力']},
                {'input': 'shiyongSwift', 'candidates': ['使用 Swift', '食用 Swift']},
                {'input': 'shiyongC++', 'candidates': ['使用 C++', '食用 C++']},
                {'input': 'lüshi', 'candidates': ['律师', '律诗']},
                {'input': 'lvshi', 'candidates': ['律师', '律诗']}]
        assign_families(rows)
        for a, b in ((0, 1), (2, 3), (4, 5)):
            self.assertEqual(rows[a]['family_id'], rows[b]['family_id'])
            self.assertEqual(rows[a]['split'], rows[b]['split'])

    def test_frozen_family_splits_actual_decoder_order_and_derivation(self):
        root = HERE / 'chinese-v1'
        dev, _, _ = load_suite(root, 'dev')
        test, _, _ = load_suite(root, 'test')
        self.assertFalse({r['family_id'] for r in dev} & {r['family_id'] for r in test})
        cases = dev + test
        coverage = validate(cases)
        self.assertGreater(coverage['cases'], 1000)
        self.assertGreater(coverage['anchors'], 300)
        self.assertGreaterEqual(len(coverage['categories']), 20)
        snapshots = {r['input']: r for r in map(json.loads, (root / 'decoder-snapshots.jsonl').read_text().splitlines())}
        overlaps = {r['anchor_id']: r['overlap'] for r in cases if not r['diagnostic']}
        regenerated = make_cases(anchors(), snapshots, overlaps) + list(diagnostics())
        self.assertEqual(sorted(cases, key=lambda r: r['id']), sorted(regenerated, key=lambda r: r['id']))
        for row in cases:
            self.assertEqual(row['split'], 'test' if row['diagnostic'] and row['track'] == 'robustness'
                             else split_for(row['family_id']))
            if row['track'].startswith('decoder'):
                self.assertEqual(row['candidate_details'], snapshots[row['input']]['candidates'])
                self.assertTrue(row['decoder']['literalAvailable'])
        report = check_readings(anchors(), REPO / 'mac/SI/Core/Resources/Chinese/si-pinyin.sqlite')
        self.assertGreater(report['candidate_checks'], 600)

    def test_matcher_suffixes_and_document_local_normalized_overlap(self):
        matcher = Matcher({'abc': {'a'}, 'bc': {'b'}, 'bcd': {'c'}})
        self.assertEqual(matcher.search('abcd'), {'a', 'b', 'c'})
        self.assertFalse(matcher.search('unrelated'))
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            rows = [{'id': 'hit', 'context': 'Ａ  B ', 'references': ['中文测试终点']},
                    {'id': 'boundary', 'context': '不能跨越', 'references': ['文档边界匹配']},
                    {'id': 'short', 'context': '', 'references': ['字']}]
            contents = {'train': ['前文a b 中文测试终点后文', '不能跨越', '文档边界匹配'],
                        'validation': ['一段不匹配的文字'], 'test': ['另一段不匹配的文字']}
            files = {}
            for split, texts in contents.items():
                path = root / (split + '.documents.jsonl')
                path.write_text(''.join(json.dumps({'text': text}) + '\n' for text in texts))
                files[path.name] = file_hash(path)
            manifest = {'files': files}
            manifest['dataset_id'] = fingerprint(manifest)
            write_json(root / 'manifest.json', manifest)
            statuses, audit = audit_overlap(rows, root)
            self.assertEqual(statuses['hit'], {'status': 'match', 'matched_splits': ['train']})
            self.assertEqual(statuses['boundary']['status'], 'clear')
            self.assertEqual(statuses['short']['status'], 'too-short')
            self.assertEqual(audit['splits']['train']['documents'], 3)
            (root / 'train.documents.jsonl').write_text('{"text":"modified"}\n')
            with self.assertRaisesRegex(ValueError, 'Modified'):
                audit_overlap(rows, root)

    def test_metrics_separate_ranking_errors_from_recall_failures(self):
        rows = []
        for family, correct, baseline, rank in [('a', False, True, 2), ('a', True, False, 1), ('b', False, False, None)]:
            rows.append({'family_id': family, 'anchor_id': str(len(rows)), 'correct': correct,
                         'baseline_correct': baseline, 'gold_rank': rank, 'gold_in_pool': rank is not None,
                         'empty_pool': rank is None, 'abstained': False, 'policy_pass': True})
        result = summarize(rows)
        self.assertAlmostEqual(result['top1_accuracy'], 1 / 3)
        self.assertAlmostEqual(result['mrr'], 0.5)
        self.assertAlmostEqual(result['candidate_recall'], 2 / 3)
        self.assertEqual(result['correct_to_wrong'], 1)
        self.assertEqual(result['wrong_to_correct'], 1)
        self.assertEqual(result['macro_family_top1'], 0.25)
        self.assertEqual(result['empty_pools'], 1)

    def test_real_tiny_checkpoint_empty_pool_abstention_integrity_and_dataset_mismatch(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            tokenizer = Tokenizer(512, list('请开始测试侧'))
            config = {'model': {'vocab_size': 512, 'layers': 1, 'width': 32, 'heads': 4,
                                'feedforward': 64, 'context': 32, 'dropout': 0.1},
                      'scoring': {'batch_size': 2, 'max_candidates': 32, 'length_penalty': 0.0}}
            with torch.random.fork_rng():
                torch.manual_seed(4)
                model = CharacterLM(config['model'], tokenizer.active_ids)
            checkpoint = root / 'model.pt'
            payload = {'schema_version': 1, 'kind': 'si-character-lm', 'config': config,
                       'tokenizer': tokenizer.to_dict(), 'tokenizer_digest': tokenizer.digest,
                       'model': model.state_dict(), 'dataset_id': 'audited-dataset', 'step': 1}
            torch.save(payload, checkpoint)
            shared = {'anchor_id': 'a', 'family_id': 'f', 'category': 'sentence', 'split': 'test',
                      'input': 'ceshi', 'context': '请开始', 'references': ['测试'], 'diagnostic': False,
                      'overlap': {'status': 'clear', 'matched_splits': []}}
            rows = [{**shared, 'id': 'ordinary', 'track': 'controlled', 'candidates': ['测试', '侧试']},
                    {**shared, 'id': 'empty', 'track': 'decoder', 'candidates': [], 'candidate_details': [],
                     'decoder': {'literalAvailable': True}},
                    {**shared, 'id': 'overlong', 'track': 'robustness', 'diagnostic': True,
                     'candidates': ['测试' * 40, '测试'], 'expected_abstained': True, 'expected_original_order': True}]
            (root / 'test.jsonl').write_text(''.join(json.dumps(row) + '\n' for row in rows))
            write_json(root / 'provenance.json', {'overlap_dataset_id': 'audited-dataset'})
            write_json(root / 'overlap-audit.json', {})
            write_json(root / 'manifest.json', {'schema_version': 1, 'files': {
                name: file_hash(root / name) for name in ('test.jsonl', 'provenance.json', 'overlap-audit.json')}})
            with contextlib.redirect_stdout(io.StringIO()):
                report = evaluate_suite(checkpoint, root, root / 'report.json', 'test', 'cpu', 2)
            self.assertTrue(report['overlap_audit_matches_model_dataset'])
            self.assertEqual(report['clean_by_track']['decoder']['empty_pools'], 1)
            self.assertEqual(report['all_by_track']['robustness']['policy_failures'], 0)
            self.assertNotIn('测试', (root / 'report.json').read_text())
            with self.assertRaises(FileExistsError):
                evaluate_suite(checkpoint, root, root / 'report.json', 'test', 'cpu', 2)
            payload['dataset_id'] = 'different-dataset'
            torch.save(payload, checkpoint)
            report = evaluate_suite(checkpoint, root, root / 'other.json', 'test', 'cpu', 2)
            self.assertFalse(report['overlap_audit_matches_model_dataset'])
            self.assertFalse(report['clean_by_track'])
            (root / 'test.jsonl').write_text('{}\n')
            with self.assertRaisesRegex(ValueError, 'modified'):
                load_suite(root, 'test')


if __name__ == '__main__':
    unittest.main()
