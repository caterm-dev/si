"""Synthetic migration checks; no HanLP installation or network required."""

import contextlib
import csv
import io
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
import migrate_chinese_vocabulary as migration
from migrate_chinese_vocabulary import convert, source_rows, word_readings


class ChineseVocabularyMigrationTests(unittest.TestCase):
    def test_model_selection_defaults_to_coarse_and_retains_fine_option(self):
        for arguments, model, cache in [
            ([], migration.MODEL, migration.CACHE),
            (['--granularity', 'fine'], migration.FINE_MODEL, migration.FINE_CACHE),
            (['--granularity', 'coarse'], migration.MODEL, migration.CACHE),
        ]:
            with self.subTest(arguments=arguments), \
                    patch.object(migration, 'configure_cache') as configure, \
                    patch.object(migration, 'load_tokenizer', return_value=('tokenizer', {})) as load, \
                    patch.object(migration, 'convert') as conversion, \
                    contextlib.redirect_stdout(io.StringIO()):
                migration.main(arguments)
                configure.assert_called_once_with(cache)
                load.assert_called_once_with('cpu', 4, model=model, cache=cache)
                self.assertEqual(conversion.call_args.args[2], 'tokenizer')
        self.assertNotEqual(migration.FINE_CACHE, migration.CACHE)

    def test_explicit_model_fetch_does_not_convert_or_load_offline(self):
        with patch.object(migration, 'configure_cache'), \
                patch.object(migration, 'fetch') as fetch, \
                patch.object(migration, 'load_tokenizer') as load, \
                patch.object(migration, 'convert') as conversion, \
                contextlib.redirect_stdout(io.StringIO()):
            migration.main(['--fetch-model'])
            fetch.assert_called_once_with(model=migration.MODEL, cache=migration.CACHE)
            load.assert_not_called()
            conversion.assert_not_called()

    def write_csv(self, path, rows):
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open('w', encoding='utf-8', newline='') as handle:
            writer = csv.writer(handle, lineterminator='\n')
            writer.writerow(['text', 'reading', 'weight'])
            writer.writerows(rows)

    def test_base_and_recursive_phrases_sum_occurrences_and_preserve_reading_identity(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, output = root / 'old', root / 'new/base.csv'
            self.write_csv(source / 'base.csv', [
                ('说', 'shuo', 1000), ('回家', "hui'jia", 200),
                ('行', 'hang', 10), ('行', 'xing', 20), ('零', 'ling', 0)])
            self.write_csv(source / 'phrase/base.csv', [
                ('说回家', "shuo'hui'jia", 760), ('说说', "shuo'shuo", 5)])
            self.write_csv(source / 'phrase/nested/extra.csv', [('说', 'shuo', 2), ('词', 'ci', '')])
            self.write_csv(source / 'movie.csv', [('说', 'shuo', 5000), ('电影', "dian'ying", 10)])
            # Invalid files outside the selected scope must not even be parsed.
            (source / 'other').mkdir()
            (source / 'other/base.csv').write_text('not a vocabulary CSV\n')
            (source / 'phrase/README.md').write_text('not a vocabulary CSV\n')
            original_files = {path: path.read_bytes() for path in source.rglob('*') if path.is_file()}

            def tokenizer(texts, **kwargs):
                return [{'说回家': ['说', '回家'], '说说': ['说', '说']}.get(text, [text])
                        for text in texts]

            with contextlib.redirect_stdout(io.StringIO()):
                convert(source, output, tokenizer, batch_size=2, chunk_rows=3)
                before = output.read_bytes()
                convert(source, output, tokenizer, batch_size=1, chunk_rows=2)
            self.assertEqual(output.read_bytes(), before)
            self.assertEqual({path: path.read_bytes() for path in original_files}, original_files)
            with output.open() as handle:
                rows = {(row['text'], row['reading']): int(row['weight']) for row in csv.DictReader(handle)}
            self.assertEqual(rows, {('说', 'shuo'): 1772, ('回家', "hui'jia"): 960,
                                    ('行', 'hang'): 10, ('行', 'xing'): 20,
                                    ('零', 'ling'): 0, ('词', 'ci'): 10})

    def test_missing_base_is_rejected_even_when_phrases_exist(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary)
            self.write_csv(source / 'phrase/base.csv', [('说', 'shuo', 10)])
            with self.assertRaisesRegex(ValueError, 'missing required base.csv'):
                list(source_rows(source))

    def test_original_polyphonic_readings_and_unicode_boundaries(self):
        self.assertEqual(word_readings('银行行长', "yin'hang'hang'zhang", ['银行', '行长']),
                         [('银行', "yin'hang"), ('行长', "hang'zhang")])
        self.assertEqual(word_readings('𠮷野回家', "ji'ye'hui'jia", ['𠮷野', '回家']),
                         [('𠮷野', "ji'ye"), ('回家', "hui'jia")])

    def test_legacy_punctuation_and_movie_aliases(self):
        cases = [
            ('F1：狂飙飞车', "ai'fu'yi'kuang'biao'fei'che", ['F', '1', '：', '狂飙', '飞车'],
             [('F', "ai'fu"), ('1', 'yi'), ('狂飙', "kuang'biao"), ('飞车', "fei'che")]),
            ('X战警：逆转未来', "ai'ke'si'zhan'jing'ni'zhuan'wei'lai", ['X战警', '：', '逆转', '未来'],
             [('X战警', "ai'ke'si'zhan'jing"), ('逆转', "ni'zhuan"), ('未来', "wei'lai")]),
            ('失恋33天', "shi'lian'san'shi'san'tian", ['失恋', '33', '天'],
             [('失恋', "shi'lian"), ('33', "san'shi'san"), ('天', 'tian')]),
            ('绣春刀II：修罗战场', "xiu'chun'dao'er'xiu'luo'zhan'chang", ['绣春刀', 'II', '：', '修罗', '战场'],
             [('绣春刀', "xiu'chun'dao"), ('II', 'er'), ('修罗', "xiu'luo"), ('战场', "zhan'chang")]),
        ]
        for text, reading, tokens, expected in cases:
            with self.subTest(text=text):
                self.assertEqual(word_readings(text, reading, tokens), expected)

    def test_invalid_boundaries_or_readings_are_rejected(self):
        for text, reading, tokens in [
            ('说回家', "shuo'hui'jia", ['说', '回']),
            ('说回家', "shuo'hui'jia", ['说', '', '回家']),
            ('说回家', "shuo'hui", ['说', '回家']),
            ('失恋33天', "shi'lian'san'shi'san'tian", ['失恋', '3', '3', '天']),
        ]:
            with self.subTest(tokens=tokens), self.assertRaises(ValueError):
                word_readings(text, reading, tokens)

    def test_failure_does_not_replace_previous_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, output = root / 'old', root / 'base.csv'
            output.write_bytes(b'previous output\n')
            self.write_csv(source / 'base.csv', [('说', 'shuo', 2**63 - 1), ('说', 'shuo', 1)])
            with self.assertRaisesRegex(ValueError, 'signed-64-bit'):
                convert(source, output, lambda texts, **kwargs: [[text] for text in texts])
            self.assertEqual(output.read_bytes(), b'previous output\n')
            with self.assertRaisesRegex(ValueError, 'outside the input tree'):
                convert(source, source / 'new.csv', None)

    def test_invalid_csv_fails_with_source_location(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary)
            for weight in ('-1', '1.5', ' 10', str(2**63)):
                self.write_csv(source / 'base.csv', [('说', 'shuo', weight)])
                with self.subTest(weight=weight), self.assertRaisesRegex(ValueError, 'base.csv:2:'):
                    list(source_rows(source))


if __name__ == '__main__':
    unittest.main()
