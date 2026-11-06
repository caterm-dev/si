import json
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
import kenlm_cleaning as c


class CleaningTests(unittest.TestCase):
    def test_shared_swift_alignment_vectors(self):
        fixture = json.loads(Path(__file__).with_name('cleaning_vectors.json').read_text())
        for case in fixture['cases']:
            with self.subTest(case=case['name']):
                self.assertEqual(c.clean_line(case['line'], fixture['counts'],
                                             set(fixture['dictionary']), case['threshold']),
                                 case['expected'])

    def test_numeric_forms_and_non_numeric_boundaries(self):
        for word in ('0', '-12', '+3.5', '.5', '-.5', '1.', '1e3', '-1.2E-4',
                     '１２３', '١٢.٣', '9' * 100):
            self.assertEqual(c.base_token(word), ('<num>', 'numeric'))
        for word in ('1,000', 'NaN', 'inf', '12kg', '+', '.', '1e', '1e+',
                     '²', 'Ⅳ', '−12', '＋12', 'v1.2', '12.3.4'):
            self.assertEqual(c.base_token(word), (word, None))

    def test_unicode_scalar_length_not_grapheme_or_utf16(self):
        self.assertEqual(c.base_token('😀' * 32), ('😀' * 32, None))
        self.assertEqual(c.base_token('😀' * 33), ('<oov>', 'long'))
        self.assertEqual(c.base_token('e\u0301' * 16), ('e\u0301' * 16, None))
        self.assertEqual(c.base_token('e\u0301' * 17), ('<oov>', 'long'))

    def test_line_rejection_precedes_all_token_mapping(self):
        for marker in c.GARBLED_MARKERS:
            self.assertIsNone(c.clean_line('保留 123 ' + marker + ' 后文', {}, set()))
        self.assertEqual(c.clean_line('正常 烫 字', {}, set()), ['正常', '烫', '字'])

    def test_exact_threshold_and_dictionary_protection(self):
        counts = {'低频': 4, '五次': 5, '十九次': 19, '二十次': 20}
        self.assertEqual(c.clean_line('低频 五次 十九次 二十次 字典', counts,
                                     {'字典'}, 5), ['<oov>', '五次', '十九次', '二十次', '字典'])
        self.assertEqual(c.clean_line('低频 五次 十九次 二十次 字典', counts,
                                     {'字典'}, 20), ['<oov>', '<oov>', '<oov>', '二十次', '字典'])

    def test_heldout_cannot_change_train_counts(self):
        counts = {'旧词': 4}
        before = counts.copy()
        for _ in range(25):
            self.assertEqual(c.clean_line('旧词 新词 专名', counts, {'专名'}, 5),
                             ['<oov>', '<oov>', '专名'])
        self.assertEqual(counts, before)

    def test_no_extra_normalization_and_markers_are_safe(self):
        self.assertEqual(c.clean_line('ABC ａｂｃ <num> <oov> !', {}, set(), 0),
                         ['ABC', 'ａｂｃ', '<num>', '<oov>', '!'])
        self.assertEqual(c.clean_line('<num> <oov>', {}, set(), 20), ['<num>', '<oov>'])
        for token in c.RESERVED:
            with self.assertRaises(ValueError):c.clean_line('文本 ' + token, {}, set())
        self.assertEqual(c.clean_line('   \n', {}, set()), [])

    def test_byte_adapter_matches_scalar_contract(self):
        mapper = c.FrozenMapper({'未知': 3}, {'词典'}, 5)
        for token in ('未知', '词典', '4.5e-2', '😀' * 33, '原样'):
            actual, reason = mapper.token(token.encode())
            expected, expected_reason = c.map_token(token, mapper.counts, mapper.dictionary, 5)
            self.assertEqual((actual.decode(), reason), (expected, expected_reason))


if __name__ == '__main__':unittest.main()
