from collections import Counter
import hashlib
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
from evaluate_conversion import DATA, load_data, paired_top1, ranking_eval, recall_eval, recall_metrics, sha256


class ConversionEvalTests(unittest.TestCase):
    def test_recent_replacements_preserve_the_reported_failure_and_reconstruct_the_old_suite(self):
        suites, manifest = load_data()
        revision = manifest['replacement_review']
        path = DATA / revision['file']
        self.assertEqual(sha256(path), revision['sha256'])
        review = json.loads(path.read_text())
        added = {row['id']: row for row in review['additions']}
        self.assertEqual(len(added), 31)
        self.assertLessEqual(max(Counter(row['family'] for row in added.values()).values()), 2)
        actual = {row['id']: row for row in suites['ranking/context-free.jsonl'] if row['id'] in added}
        self.assertEqual(actual, added)
        completion = next(row for row in actual.values() if row['input'] == 'bazhegezuowan')
        self.assertEqual(completion['references'], ['把这个做完'])
        self.assertIn('把这个昨晚', completion['candidates'])
        retired_ids = {row['row']['id'] for row in review['retired_rows']}
        self.assertEqual(len(retired_ids), 35)
        self.assertTrue(set(review['requested_error_ids']) <= retired_ids)
        self.assertTrue(retired_ids.isdisjoint(row['id'] for rows in suites.values() for row in rows))
        for name, expected_hash in review['previous_hashes'].items():
            removed = {row['line']: row['original_line'] for row in review['retired_rows'] if row['source'] == name}
            remaining = [line for line in (DATA / name).read_text().splitlines()
                         if json.loads(line)['id'] not in added]
            iterator = iter(remaining)
            reconstructed = [removed[i] if i in removed else next(iterator)
                             for i in range(1, len(remaining) + len(removed) + 1)]
            self.assertEqual(hashlib.sha256(('\n'.join(reconstructed) + '\n').encode()).hexdigest(), expected_hash)

    def test_recall_requires_a_whole_exact_candidate_in_the_requested_language(self):
        query = {'id': 'one', 'input': 'he', 'context': '', 'languages': ['zh-Hans', 'en'],
                 'category': 'fixture', 'reference_language': 'zh-Hans', 'references': ['河']}
        output = (
            'zh-Hans\t1\tprefix\t-1\t河\n'
            'en\t2\texact\t-2\t河\n'
            'zh-Hans\t2\tcompletion\t-3\t河\n'
            'zh-Hans\t2\texact\t-4\t河\n'
            'literal\t2\tliteral\t\the\n\n'
        )
        with patch('evaluate_conversion.external', return_value=output) as cli:
            hit, = recall_eval([query], 'cli', 'dictionary', 'ngrams')
            cli.assert_called_once()
            self.assertEqual(cli.call_args.args[1], 'he\n')
        self.assertEqual(hit['rank'], 2)
        self.assertEqual(hit['eligible_count'], 2)
        self.assertEqual(len(hit['candidates']), 5)
        with patch('evaluate_conversion.external', return_value=output.replace('exact\t-4', 'correction\t-4')):
            miss, = recall_eval([query], 'cli', 'dictionary', 'ngrams')
        self.assertIsNone(miss['rank'])
        self.assertEqual(recall_metrics([hit, miss])['full_pool_hits'], 1)

    def test_context_ablation_preserves_candidate_order_and_omits_references(self):
        pool = ['盒', '河']
        pair = [
            {'id': 'a', 'pair': 'one', 'category': 'fixture', 'pool_origin': 'fixture',
             'context': '找一个纸', 'candidates': pool, 'references': ['盒']},
            {'id': 'b', 'pair': 'one', 'category': 'fixture', 'pool_origin': 'fixture',
             'context': '水从村前的小', 'candidates': pool, 'references': ['河']},
        ]

        def rank(_command, request):
            replies = []
            for line in request.splitlines():
                row = json.loads(line)
                self.assertEqual(set(row), {'candidates', 'context'})
                self.assertEqual(row['candidates'], pool)
                prefers_river = row['context'] == pair[1]['context']
                replies.append(json.dumps({
                    'order': [1, 0] if prefers_river else [0, 1],
                    'scores': [-3, -1] if prefers_river else [-1, -3],
                    'abstained': False,
                }))
            return '\n'.join(replies)

        with patch('evaluate_conversion.external', side_effect=rank):
            actual = ranking_eval(pair, 'cli', 'model', True)
            ablated = ranking_eval(pair, 'cli', 'model', False)
        self.assertEqual(paired_top1(pair, actual)['both_top1'], 1)
        self.assertEqual(paired_top1(pair, ablated)['both_top1'], 0)
