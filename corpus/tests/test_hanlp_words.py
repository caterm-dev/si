"""Synthetic boundary/count checks; no pretrained model or network required."""

from collections import Counter
import contextlib
import csv
import io
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from common import digest
from check_word_corrections import count_spans
from hanlp_words import count_tokens, segment, tokenize_chunk, verify
from review_words import eligibility


class HanLPWordCountTests(unittest.TestCase):
    def test_surface_evidence_counts_overlaps_without_crossing_fragments(self):
        words = {'测试', '试测', '试文'}
        self.assertEqual(count_spans('测试测试', words), {'测试': 2, '试测': 1})
        separate = count_spans('测试', words) + count_spans('文本', words)
        self.assertEqual(separate, {'测试': 1})

    def test_occurrences_are_distinct_from_fragment_frequency(self):
        counts, lines = Counter(), Counter()
        count_tokens(['测试测试文本', '测试词频'],
                     [['测试', '测试', '文本'], ['测试', '词频']], counts, lines)
        self.assertEqual(counts, {'测试': 3, '文本': 1, '词频': 1})
        self.assertEqual(lines, {'测试': 2, '文本': 1, '词频': 1})

    def test_missing_or_changed_output_is_rejected(self):
        for tokens in ([], [['测试']], [['测试', '文本', '']], [['测试', '文字']]):
            with self.subTest(tokens=tokens), self.assertRaises(ValueError):
                count_tokens(['测试文本'], tokens, Counter(), Counter())

    def test_supplementary_han_boundaries_remain_exact(self):
        counts, lines = Counter(), Counter()
        count_tokens(['𠮷野测试'], [['𠮷野', '测试']], counts, lines)
        self.assertEqual(counts['𠮷野'], 1)

    def test_length_grouping_restores_source_order(self):
        texts = ['测试分词工具', '测试', '分词工具']
        def tokenizer(batch, **kwargs):
            self.assertIsNone(kwargs['sampler_builder'])
            return [[text] for text in batch]
        self.assertEqual(tokenize_chunk(tokenizer, texts, 2), [[text] for text in texts])

    def test_review_requires_frequency_and_independent_fragment_support(self):
        self.assertEqual(eligibility('测试词', 19, 19, 3), 'low_frequency')
        self.assertEqual(eligibility('测试词', 200, 9, 3), 'low_frequency')
        self.assertEqual(eligibility('测试词', 50, 40, 1), 'insufficient_source_support')
        self.assertEqual(eligibility('测试词', 20, 10, 2), 'review')
        self.assertEqual(eligibility('测试词', 100, 100, 1), 'review')
        self.assertEqual(eligibility('哈哈', 200, 100, 2), 'repeated_character')
        self.assertEqual(eligibility('测试x', 200, 100, 2), 'outside_length_or_script')

    def test_completed_chunks_resume_without_double_counting_and_reject_tampering(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bundle = root / 'bundle'
            source = bundle / 'fixture'
            source.mkdir(parents=True)
            (bundle / 'sources.lock.json').write_text('{}\n')
            texts = ['测试测试', '测试词频', '词频测试']
            (source / 'text.txt').write_text('\n'.join(texts) + '\n')
            (source / 'origins.jsonl').write_text('"synthetic"\n' * 3)
            metadata = {'source': {'id': 'fixture'}, 'counts': {'lines': 3, 'characters': 12},
                        'files': {name: {'sha256': digest(source / name), 'bytes': (source / name).stat().st_size}
                                  for name in ('text.txt', 'origins.jsonl')}}
            (bundle / 'manifest.json').write_text(json.dumps({
                'source_lock_sha256': digest(bundle / 'sources.lock.json'), 'sources': [metadata]}))
            calls = []

            def tokenizer(batch, **kwargs):
                calls.append(batch)
                return [[text[i:i + 2] for i in range(0, len(text), 2)] for text in batch]

            args = SimpleNamespace(bundle=[bundle], output=root / 'output', device='cpu', threads=1,
                                   batch_size=2, chunk_lines=2)
            with patch('hanlp_words.load_tokenizer', return_value=(tokenizer, {})), \
                    contextlib.redirect_stdout(io.StringIO()):
                segment(args)
                self.assertEqual(len(calls), 2)
                verify(args)
                counts_path = args.output / 'fixture/counts.csv'
                before = counts_path.read_bytes()
                segment(args)
                self.assertEqual(len(calls), 2)
                self.assertEqual(before, counts_path.read_bytes())
                with counts_path.open() as handle:
                    rows = {r['text']: (int(r['count']), int(r['line_count'])) for r in csv.DictReader(handle)}
                self.assertEqual(rows, {'测试': (4, 3), '词频': (2, 2)})
                (args.output / 'fixture/00000/counts.csv').write_text('corrupt\n')
                with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
                    segment(args)


if __name__ == '__main__':
    unittest.main()
