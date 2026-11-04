import copy
import csv
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from eval.datasets import ROOT, TASKS, digest, load, read_json, requests, validate_rows, write_new
from eval.scoring import compare, score


def prediction(identity, values, name='test-algorithm'):
    return {**identity, 'predictor': {'name': name, 'revision': 'test-v1'}, 'predictions': values}


def case(identity, **values):
    return {'id': identity, 'family_id': identity, 'split': 'test', 'context': '',
            'category': 'fixture', 'track': 'fixture', 'diagnostic': False,
            'input': 'spelling', 'references': ['目标'], **values}


class DatasetTests(unittest.TestCase):
    def test_all_frozen_suites_counts_and_ranking_legacy_bytes(self):
        expected = {'ranking': (299, 931), 'correction': (25, 55), 'pinyin_to_hanzi': (69, 64)}
        for task in TASKS:
            for split, count in zip(('dev', 'test'), expected[task]):
                identity, rows, _ = load(task, split)
                self.assertEqual(len(rows), count)
                self.assertEqual(len({r['id'] for r in rows}), count)
                if task == 'ranking':
                    self.assertEqual(identity['dataset_sha256'], 'd12b5acb3ffc61a77309090ef7663844e14621e732ccf792e12a7d0e1b44f6aa')
        legacy = ROOT.parent / 'llm/reranker_small/benchmarks/chinese-v1'
        self.assertEqual(legacy.resolve(), ROOT / 'ranking/chinese-v1')
        for name in ('manifest.json', 'dev.jsonl', 'test.jsonl'):
            self.assertEqual(digest(legacy / name), digest(ROOT / 'ranking/chinese-v1' / name))

    def test_pinyin_exact_original_rows_grouped_with_all_accepted_outputs(self):
        for old, split in (('validation', 'dev'), ('test', 'test')):
            expected = {}
            directory = ROOT / 'pinyin_to_hanzi/lexical-v1'
            for path in sorted((directory / 'sources' / old).glob('*.csv')):
                with path.open(encoding='utf-8') as handle:
                    for row in csv.DictReader(handle):
                        expected.setdefault(row['input'], set()).add(row['target'])
            _, rows, _ = load('pinyin_to_hanzi', split)
            self.assertEqual({r['input']: set(r['references']) for r in rows}, expected)
            for row in rows:
                for source in row['sources']:
                    with (directory / source['file']).open(encoding='utf-8') as handle:
                        lines = list(csv.reader(handle))
                    raw, target = lines[source['line'] - 1]
                    self.assertEqual(raw, row['input'])
                    self.assertIn(target, row['references'])

    def test_corrupted_file_and_manifest_are_rejected_before_scoring(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / 'eval'
            shutil.copytree(ROOT / 'correction', root / 'correction')
            shutil.copyfile(ROOT / 'catalog.json', root / 'catalog.json')
            data = root / 'correction/synthetic-v1/dev.jsonl'
            original = data.read_bytes()
            data.write_bytes(original + b'{}\n')
            with self.assertRaisesRegex(ValueError, 'file modified'):
                load('correction', root=root)
            data.write_bytes(original)
            manifest = data.parent / 'manifest.json'
            manifest.write_text(manifest.read_text() + '\n')
            with self.assertRaisesRegex(ValueError, 'manifest modified'):
                load('correction', root=root)

    def test_requests_have_no_answers_or_policy_labels(self):
        allowed = {'id', 'input', 'context', 'candidates', 'candidate_details'}
        for task in TASKS:
            identity, rows, _ = load(task)
            blind = requests(identity, rows)
            self.assertEqual(len(blind['cases']), len(rows))
            self.assertTrue(all(set(row) <= allowed for row in blind['cases']))
            self.assertNotIn('references', json.dumps(blind))

    def test_family_and_normalized_target_overlap_rejected(self):
        rows = [case('one', split='dev', candidates=['目标']), case('two', family_id='one', candidates=['目标'])]
        with self.assertRaisesRegex(ValueError, 'Family crosses'):
            validate_rows(rows, 'ranking')
        rows = [case('one', split='dev', input='a', references=['café']),
                case('two', input='b', references=['cafe\u0301'])]
        with self.assertRaisesRegex(ValueError, 'crosses dev/test'):
            validate_rows(rows, 'correction')


class ScoringTests(unittest.TestCase):
    def setUp(self):
        self.identity = {'schema_version': 1, 'task': 'ranking', 'suite': 'fixture',
                         'split': 'test', 'dataset_sha256': 'fixture-hash'}

    def test_ranking_missing_gold_empty_equal_text_identities_and_diagnostics(self):
        rows = [case('equal', candidates=['目标', '目标'], candidate_details=[
                    {'text': '目标', 'identity': 'zh/1'}, {'text': '目标', 'identity': 'en/2'}]),
                case('missing', candidates=['其他']), case('empty', candidates=[]),
                case('diagnostic', candidates=['其他', '目标'], diagnostic=True,
                     expected_original_order=True, expected_abstained=True)]
        values = [{'id': 'equal', 'order': [1, 0], 'abstained': False},
                  {'id': 'missing', 'order': [0], 'abstained': False},
                  {'id': 'empty', 'order': [], 'abstained': False},
                  {'id': 'diagnostic', 'order': [0, 1], 'abstained': True}]
        report = score(self.identity, rows, {}, prediction(self.identity, values))
        metrics = report['metrics']['by_track']['fixture']
        self.assertEqual(metrics['cases'], 3)
        self.assertAlmostEqual(metrics['top1_accuracy'], 1 / 3)
        self.assertAlmostEqual(metrics['candidate_recall'], 1 / 3)
        self.assertEqual(metrics['top1_when_gold_available'], 1)
        self.assertEqual(metrics['empty_pools'], 1)
        self.assertEqual(report['diagnostics_by_track']['fixture']['policy_failures'], 0)
        self.assertNotIn('目标', json.dumps(report, ensure_ascii=False))

    def test_coverage_identity_permutation_and_abstention_contracts(self):
        rows = [case('a', candidates=['目标', '其他'])]
        valid = prediction(self.identity, [{'id': 'a', 'order': [0, 1], 'abstained': False}])
        for change in (lambda p: p.update(split='dev'), lambda p: p.update(dataset_sha256='other'),
                       lambda p: p.update(predictions=[]), lambda p: p['predictions'].append(p['predictions'][0]),
                       lambda p: p['predictions'][0].update(id='unknown'),
                       lambda p: p['predictions'][0].update(order=[0, 0]),
                       lambda p: p['predictions'][0].update(order=[False, 1]),
                       lambda p: p['predictions'][0].update(order=[1, 0], abstained=True)):
            payload = copy.deepcopy(valid)
            change(payload)
            with self.assertRaises(ValueError):
                score(self.identity, rows, {}, payload)

    def test_generation_exact_unicode_multiple_references_and_overcorrection(self):
        identity = {**self.identity, 'task': 'correction'}
        rows = [case('correct', input='错', references=['对', '正确']),
                case('keep', input='café', references=['café']),
                case('absent', input='未', references=['𠮷'])]
        values = [{'id': 'correct', 'outputs': ['正确']}, {'id': 'keep', 'outputs': ['cafe\u0301']},
                  {'id': 'absent', 'outputs': []}]
        report = score(identity, rows, {}, prediction(identity, values))
        metrics = report['metrics']['overall']
        self.assertAlmostEqual(metrics['top1_accuracy'], 1 / 3)
        self.assertEqual(metrics['overcorrection_rate'], 1)
        self.assertEqual(metrics['correction_accuracy'], 0.5)
        self.assertEqual(metrics['abstentions'], 1)
        self.assertEqual(metrics['character_error_rate'], 3 / 7)
        values[0]['outputs'] = ['正确', '正确']
        with self.assertRaisesRegex(ValueError, 'distinct'):
            score(identity, rows, {}, prediction(identity, values))

    def test_clean_ranking_metrics_only_for_matching_declared_training_dataset(self):
        rows = [case('a', candidates=['目标'], overlap={'status': 'clear'})]
        payload = prediction(self.identity, [{'id': 'a', 'order': [0], 'abstained': False}])
        for declared, expected in ((None, False), ('other', False), ('audited', True)):
            payload['predictor']['training_dataset_id'] = declared
            report = score(self.identity, rows, {'overlap_dataset_id': 'audited'}, payload)
            self.assertEqual(bool(report['metrics']['clean_by_track']), expected)

    def test_comparison_refuses_different_datasets_splits_and_scorers(self):
        rows = [case('a', candidates=['目标'])]
        a = score(self.identity, rows, {}, prediction(self.identity, [{'id': 'a', 'order': [0], 'abstained': False}]))
        b = copy.deepcopy(a)
        b['predictor']['name'] = 'large-or-other-algorithm'
        self.assertEqual(len(compare([a, b])['models']), 2)
        for key in ('task', 'suite', 'split', 'dataset_sha256', 'scorer_sha256', 'evaluated_cases', 'partial'):
            changed = copy.deepcopy(b)
            changed[key] = 'different'
            with self.assertRaises(ValueError):
                compare([a, changed])

    def test_cli_roundtrip_all_tasks_and_no_overwrite(self):
        with tempfile.TemporaryDirectory() as temporary:
            for task in TASKS:
                path = Path(temporary)
                predictions, report = path / (task + '-pred.json'), path / (task + '-report.json')
                common = [sys.executable, '-m', 'eval']
                subprocess.run([*common, 'baseline', '--task', task, '--split', 'dev', '--output', str(predictions)],
                               cwd=ROOT.parent, check=True, capture_output=True)
                subprocess.run([*common, 'score', '--task', task, '--split', 'dev', '--predictions', str(predictions),
                                '--output', str(report)], cwd=ROOT.parent, check=True, capture_output=True)
                self.assertFalse(read_json(report)['partial'])
                with self.assertRaises(FileExistsError):
                    write_new(report, {})


@unittest.skipUnless(importlib.util.find_spec('torch'), 'optional PyTorch adapter tests use llm/.venv')
class AdapterTests(unittest.TestCase):
    def test_real_tiny_small_checkpoint_inference_to_common_score(self):
        import torch
        from eval.adapters import predict_small
        from llm.reranker_small.model import CharacterLM
        from llm.reranker_small.tokenizer import Tokenizer

        identity = {'schema_version': 1, 'task': 'ranking', 'suite': 'tiny', 'split': 'test', 'dataset_sha256': 'tiny'}
        rows = [case('a', candidates=['目标', '其他']), case('empty', candidates=[]),
                case('long', candidates=['目标' * 40, '目标'], diagnostic=True,
                     expected_abstained=True, expected_original_order=True)]
        tokenizer = Tokenizer(512, list('目标其他'))
        config = {'model': {'vocab_size': 512, 'layers': 1, 'width': 32, 'heads': 4,
                            'feedforward': 64, 'context': 32, 'dropout': 0.0},
                  'scoring': {'batch_size': 2, 'max_candidates': 32, 'length_penalty': 0.0}}
        with torch.random.fork_rng():
            model = CharacterLM(config['model'], tokenizer.active_ids)
        with tempfile.TemporaryDirectory() as temporary:
            checkpoint = Path(temporary) / 'tiny.pt'
            torch.save({'schema_version': 1, 'kind': 'si-character-lm', 'config': config,
                        'tokenizer': tokenizer.to_dict(), 'tokenizer_digest': tokenizer.digest,
                        'model': model.state_dict(), 'dataset_id': 'tiny', 'step': 0}, checkpoint)
            output = predict_small(identity, requests(identity, rows)['cases'], checkpoint, 'cpu', 2)
        report = score(identity, rows, {}, output)
        self.assertEqual(report['evaluated_cases'], 3)
        self.assertEqual(report['diagnostics_by_track']['fixture']['policy_failures'], 0)

    def test_real_tiny_converter_does_not_synthesize_literal_fallback(self):
        import torch
        from eval.adapters import predict_converter
        from llm.pinyin_to_text.model import SpellingTransformer
        from llm.pinyin_to_text.tokenizer import Tokenizer

        identity = {'schema_version': 1, 'task': 'pinyin_to_hanzi', 'suite': 'tiny', 'split': 'test', 'dataset_sha256': 'tiny'}
        rows = [case('too-long', input='z' * 100), case('short', input='z')]
        config = read_json(ROOT.parent / 'llm/pinyin_to_text/configs/smoke.json')
        config['model'].update(max_source_tokens=8, max_target_tokens=8)
        tokenizer = Tokenizer(512, list('z目标'))
        with torch.random.fork_rng():
            model = SpellingTransformer(config['model'], tokenizer.active_ids)
        with tempfile.TemporaryDirectory() as temporary:
            checkpoint = Path(temporary) / 'tiny.pt'
            torch.save({'schema_version': 1, 'config': config, 'tokenizer': tokenizer.to_dict(),
                        'tokenizer_digest': tokenizer.digest, 'model': model.state_dict(),
                        'dataset_id': 'tiny', 'step': 0}, checkpoint)
            output = predict_converter(identity, requests(identity, rows)['cases'], checkpoint, 'cpu', 2)
        self.assertEqual(output['predictions'][0]['outputs'], [])
        self.assertEqual(len(output['predictions']), 2)
        self.assertGreaterEqual(score(identity, rows, {}, output)['metrics']['overall']['abstentions'], 1)


if __name__ == '__main__':
    unittest.main()
