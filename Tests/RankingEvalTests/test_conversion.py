import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
from evaluate_conversion import paired_top1, ranking_eval, recall_eval, recall_metrics


class ConversionEvalTests(unittest.TestCase):
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
