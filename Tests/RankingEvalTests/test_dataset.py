import copy
from collections import Counter
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
from generate_ranking_eval import COUNT, MAX_PER_FAMILY, generate, validate
from ranking_eval import load, score


class RankingEvalTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.rows, cls.identity = load()

    def test_frozen_reproduction_and_requested_regressions(self):
        self.assertEqual(self.rows, generate())
        self.assertEqual(len(self.rows), COUNT)
        cases = {r['input']: r for r in self.rows}
        for source, expected in [('zhaojichujuzi', '找几处句子'), ('erbeizuoduo', '二倍做多'),
                                 ('woxianganzhao', '我想按照'), ('heshangcibi', '和上次比'),
                                 ('xianzaitianjiazimu', '现在添加字幕'), ('goon', 'go on'),
                                 ('cannot', 'cannot'), ('diqiye', '第七页'), ('houxuanchi', '候选池'),
                                 ('dajiaxiazhouxiangqubeihaiguzhen', '大家下周想去北海古镇')]:
            self.assertIn(expected, cases[source]['references'])
        self.assertNotIn('sheguofennudehai', cases)
        self.assertNotIn("she'guo'fen'nu'de'hai", cases)
        self.assertEqual(cases['woxianganzhao']['family'], cases["wo'xiang'an'zhao"]['family'])
        self.assertFalse(any('candidates' in r for r in self.rows))

    def test_representatives_do_not_expand_into_slot_or_number_series(self):
        counts = Counter(r['family'] for r in self.rows)
        self.assertLessEqual(max(counts.values()), MAX_PER_FAMILY)
        shopping = [r for r in self.rows if '想买绿色' in r['references'][0]]
        self.assertEqual(len(shopping), 2)
        self.assertEqual({r['references'][0] for r in shopping}, {'我想买绿色背包'})
        ordinals = [r for r in self.rows if r['category'] == 'ordinal']
        self.assertEqual(len(ordinals), 6)
        for unit in ('页', '章', '节', '段', '行'):
            self.assertLessEqual(sum(r['references'][0].endswith(unit) for r in ordinals), 2)
        self.assertEqual(sum(r['category'] == 'english-sentence' for r in self.rows), 2)
        rows = copy.deepcopy(self.rows)
        rows[-1]['family'] = rows[0]['family']
        with self.assertRaisesRegex(ValueError, 'near-duplicate'):
            validate(rows)

    def test_duplicates_and_changed_alias_alignment_fail(self):
        rows = copy.deepcopy(self.rows)
        rows[-1]['input'] = rows[0]['input']
        with self.assertRaisesRegex(ValueError, 'Repeated'):
            validate(rows)
        rows = copy.deepcopy(self.rows)
        row = next(r for r in rows if r['category'] == 'umlaut-alias')
        row['input'] += 'x'
        with self.assertRaisesRegex(ValueError, 'alignment'):
            validate(rows)

    def test_missing_gold_empty_pools_exact_bytes_and_language_identity(self):
        cases = [{'id': 'a', 'input': 'foo', 'references': ['测试'], 'category': 'test', 'family': 'one', 'languages': ['en', 'zh-Hans']},
                 {'id': 'b', 'input': 'bar', 'references': ['café'], 'category': 'test', 'family': 'two', 'languages': ['en', 'zh-Hans']},
                 {'id': 'c', 'input': 'baz', 'references': ['不存在'], 'category': 'test', 'family': 'two', 'languages': ['en', 'zh-Hans']}]
        predictions = [
            {'id': 'a', 'input': 'foo', 'literalAvailable': True, 'totalEligible': 2,
             'candidates': [{'identity': 'en:test', 'text': 'wrong', 'language': 'en'},
                            {'identity': 'zh:test', 'text': '测试', 'language': 'zh-Hans'}]},
            {'id': 'b', 'input': 'bar', 'literalAvailable': True, 'totalEligible': 1,
             'candidates': [{'identity': 'en:cafe', 'text': 'cafe\u0301', 'language': 'en'}]},
            {'id': 'c', 'input': 'baz', 'literalAvailable': True, 'totalEligible': 0, 'candidates': []},
        ]
        report = score(cases, predictions)
        self.assertAlmostEqual(report['overall']['exported_pool_recall'], 1 / 3)
        self.assertEqual(report['overall']['top1'], 0)
        self.assertAlmostEqual(report['overall']['top5'], 1 / 3)
        self.assertAlmostEqual(report['overall']['mrr'], 1 / 6)
        with self.assertRaisesRegex(ValueError, 'Incomplete'):
            score(cases, predictions[:-1])
        with self.assertRaisesRegex(ValueError, 'repeated'):
            score(cases, predictions + [predictions[0]])
        broken = copy.deepcopy(predictions)
        broken[0]['candidates'][1]['identity'] = 'en:test'
        with self.assertRaisesRegex(ValueError, 'identity'):
            score(cases, broken)
        broken = copy.deepcopy(predictions)
        broken[0]['candidates'].pop()
        with self.assertRaisesRegex(ValueError, 'Truncated'):
            score(cases, broken)
        # Equal text from different languages retains both distinct identities.
        predictions[0]['candidates'][0]['text'] = '测试'
        self.assertEqual(score(cases, predictions)['overall']['top1'], 1 / 3)


if __name__ == '__main__':
    unittest.main()
