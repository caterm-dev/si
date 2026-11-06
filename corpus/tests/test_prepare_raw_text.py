"""Raw extraction regressions: retain numbers, punctuation, short text and repeats."""

from collections import Counter
import bz2
import gzip
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from prepare_raw_text import extract, raw_documents


class RawTextPreparationTests(unittest.TestCase):
    def test_mc4_keeps_complete_lines_short_english_and_repeated_records(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / 'source.gz'
            title = '关于2017年候选人的通知，金额12.50元。短句、English co-op！'
            with gzip.open(archive, 'wt', encoding='utf-8') as handle:
                for text in (title, title, 'English only 2026.', '短', '正文' * 70):
                    handle.write(json.dumps({'text': text, 'url': 'https://example.invalid/'}) + '\n')
            source = {'id': 'synthetic', 'kind': 'mc4'}
            output = root / 'output'
            manifest = extract(source, archive, output)
            lines = (output / 'text.txt').read_text().splitlines()
            self.assertEqual(lines[:4], [title, title, 'English only 2026.', '短'])
            self.assertEqual(lines[4], '正文' * 70)
            self.assertEqual(manifest['counts']['records_read'], 5)
            origins = [json.loads(line) for line in (output / 'documents.jsonl').read_text().splitlines()]
            self.assertEqual([row['first_line'] for row in origins], [1, 2, 3, 4, 5])
            self.assertEqual(origins[0]['url'], 'https://example.invalid/')
            self.assertEqual(extract(source, archive, output), manifest)
            (output / 'text.txt').write_text('Changed')
            with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
                extract(source, archive, output)

    def test_lccc_restores_han_tokens_without_joining_english_or_removing_digits(self):
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / 'dialogue.gz'
            with gzip.open(archive, 'wt', encoding='utf-8') as handle:
                handle.write(json.dumps(['我们 测试 ， 使用 Python tools 2017 年 。', '短 句']) + '\n')
            rows = list(raw_documents({'kind': 'lccc'}, archive, Counter()))
            self.assertEqual(rows, [('row:1/turn:0', '我们测试，使用 Python tools 2017 年。', {}),
                                    ('row:1/turn:1', '短句', {})])

    def test_wikipedia_keeps_article_title_numbers_punctuation_and_english(self):
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / 'wiki.bz2'
            archive.write_bytes(bz2.compress((
                '<mediawiki><page><title>标题2017</title><ns>0</ns><id>1</id>'
                '<revision><id>11</id><text>正文2017年，English tools。\n短。</text></revision></page>'
                '<page><title>模板</title><ns>10</ns><id>2</id>'
                '<revision><id>12</id><text>非正文</text></revision></page></mediawiki>'
            ).encode()))
            result = list(raw_documents({'kind': 'wikipedia'}, archive, Counter()))
            self.assertEqual(len(result), 1)
            self.assertEqual(result[0][1], '标题2017\n\n正文2017年，English tools。\n短。')

    def test_utf8_serialization_and_failed_record_do_not_publish_partial_data(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / 'source.gz'
            with gzip.open(archive, 'wt', encoding='utf-8') as handle:
                handle.write(json.dumps({'text': '保持\ud800数字2017\r\n下一行'}) + '\n')
            result = extract({'id': 'fixture', 'kind': 'mc4'}, archive, root / 'valid')
            self.assertEqual((root / 'valid/text.txt').read_text(), '保持数字2017\n下一行\n')
            self.assertEqual(result['counts']['surrogates_removed'], 1)
            with gzip.open(archive, 'wt', encoding='utf-8') as handle:
                handle.write(json.dumps({'text': '正常2017。'}) + '\n')
                handle.write(json.dumps({'text': 42}) + '\n')
            with self.assertRaisesRegex(ValueError, 'row 2'):
                extract({'id': 'fixture', 'kind': 'mc4'}, archive, root / 'invalid')
            self.assertFalse((root / 'invalid').exists())


if __name__ == '__main__':
    unittest.main()
