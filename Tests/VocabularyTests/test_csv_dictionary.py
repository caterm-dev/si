"""Synthetic category maintenance, byte/tie preservation and failure-safety fixtures."""
import contextlib
import csv
import io
import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
import csv_dictionary as dictionary
import lexicon_database as lexicon


class CSVDictionaryTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.data = self.root / 'data'
        self.output = self.root / 'output'
        for language in dictionary.DATABASES:
            (self.data / language).mkdir(parents=True)
        (self.root / 'NOTICE').write_bytes(b'Synthetic attribution')
        checksum = dictionary.digest(b'Synthetic attribution')
        self.meta = {'schema_version': 2, 'dictionary_format': lexicon.FORMAT,
                     'languages': {name: {'unknown_weight': 9 if name == 'english' else 1}
                                   for name in dictionary.DATABASES},
                     'upstreams': [{'id': 'synthetic', 'metadata': {'source': 'Synthetic fixture'},
                                    'attribution': 'NOTICE', 'attribution_sha256': checksum}]}
        self.save_meta()
        self.csv('chinese', 'base', [('呢', 'ne', 20), ('讷', 'ne', 5),
                                     ('内', 'nei', 5), ('你好', "ni'hao", 100)])
        self.csv('english', 'base', [('Apple', 'apple', 20), ('alpha', 'alpha', 5)])
        patches = patch.multiple(dictionary, ROOT=self.root, DATA=self.data, RESOURCES=self.output)
        patches.start()
        self.addCleanup(patches.stop)

    def save_meta(self):
        (self.data / 'meta.json').write_text(json.dumps(self.meta))

    def csv(self, language, category, entries):
        path = self.data / language / (category + '.csv')
        with path.open('w', encoding='utf-8', newline='') as stream:
            writer = csv.writer(stream, lineterminator='\n')
            writer.writerow(dictionary.COLUMNS)
            writer.writerows(entries)
        return path

    def build(self, check=False):
        with contextlib.redirect_stdout(io.StringIO()):
            dictionary.build(check)

    def files(self):
        return {str(p.relative_to(self.output)): (p.read_bytes(), p.stat().st_mtime_ns)
                for p in self.output.rglob('*') if p.is_file()}

    def query(self, language, query):
        path = self.output / language.title() / dictionary.DATABASES[language]
        with sqlite3.connect(path) as connection:
            return connection.execute(query).fetchall()

    def test_both_languages_share_schema_metadata_weights_and_generated_tie_order(self):
        self.build()
        self.assertEqual(self.query('chinese', 'SELECT key,jp,value,weight FROM tbl_1_n ORDER BY weight DESC,rowid'),
                         [('ne', 'n', '呢', 20), ('ne', 'n', '讷', 5), ('nei', 'n', '内', 5)])
        self.assertEqual(self.query('chinese', 'SELECT key,jp,value,weight FROM tbl_2_n'),
                         [("ni'hao", 'nh', '你好', 100)])
        for language, unknown in [('chinese', '1'), ('english', '9')]:
            self.assertEqual(self.query(language, 'PRAGMA integrity_check'), [('ok',)])
            metadata = dict(self.query(language, 'SELECT key,value FROM dictionary_metadata'))
            self.assertEqual(metadata['unknown_weight'], unknown)
            self.assertEqual(metadata['weight_unit'], lexicon.FORMAT['weight_unit'])
            self.assertEqual(int(metadata['reference_mass']), lexicon.FORMAT['reference_mass'])
        self.assertEqual(self.query('chinese', "SELECT sql FROM sqlite_master WHERE sql IS NOT NULL ORDER BY name"),
                         self.query('english', "SELECT sql FROM sqlite_master WHERE sql IS NOT NULL ORDER BY name"))
        before = self.files()
        self.build(check=True)
        self.assertEqual(before, self.files())

    def test_category_discovery_moves_additions_deletions_and_weight_edits(self):
        self.build()
        # Moving a row to a new category preserves every runtime row without a maintained ID.
        path = self.csv('chinese', 'base', [('呢', 'ne', 20), ('内', 'nei', 5), ('你好', "ni'hao", 100)])
        self.csv('chinese', 'technology', [('讷', 'ne', 5)])
        old_database = self.output / 'Chinese/si-pinyin.sqlite'
        old_copy = self.root / 'before.sqlite'
        old_copy.write_bytes(old_database.read_bytes())
        self.build()
        self.assertTrue(lexicon.same_dictionary(old_copy, old_database))
        self.csv('chinese', 'technology', [('讷', 'ne', 25), ('哪', 'ne', 5), ('呐', 'ne', 0)])
        self.csv('english', 'companies', [('GitHub', 'github', 50)])
        self.build()
        self.assertEqual(self.query('chinese', "SELECT value FROM tbl_1_n WHERE key='ne' ORDER BY weight DESC,rowid"),
                         [('讷',), ('呢',), ('哪',), ('呐',)])
        self.assertEqual(self.query('english', 'SELECT value FROM tbl_1_g'), [('GitHub',)])
        # Deleting from CSV is authoritative: no old overlay or upstream re-addition.
        path.write_text('text,reading,weight\n你好,ni\'hao,100\n')
        self.build()
        self.assertEqual(self.query('chinese', "SELECT value FROM tbl_1_n WHERE key='ne' ORDER BY weight DESC,rowid"), [('讷',), ('哪',), ('呐',)])

    def test_blank_local_weights_default_to_ten_but_imported_weights_stay_explicit(self):
        self.csv('chinese', 'custom', [('新', 'xin', ''), ('零', 'ling', 0)])
        self.csv('english', 'custom', [('example', 'example', '')])
        self.build()
        self.assertEqual(self.query('chinese', "SELECT value,weight FROM tbl_1_x WHERE value='新'"), [('新', 10)])
        self.assertEqual(self.query('chinese', "SELECT value,weight FROM tbl_1_l WHERE value='零'"), [('零', 0)])
        self.assertEqual(self.query('english', "SELECT value,weight FROM tbl_1_e WHERE value='example'"), [('example', 10)])
        before = self.files()
        self.csv('chinese', 'diming', [('城', 'cheng', '')])
        self.meta['upstream_categories'] = {'chinese': ['diming.csv']}
        self.save_meta()
        with self.assertRaisesRegex(ValueError, 'Invalid weight'):
            self.build()
        self.assertEqual(before, self.files())
        self.csv('chinese', 'diming', [('城', 'cheng', 1)])
        self.csv('english', 'base', [('Apple', 'apple', '')])
        with self.assertRaisesRegex(ValueError, 'Invalid weight'):
            self.build()
        self.assertEqual(before, self.files())

    def test_csv_quoting_bom_crlf_and_exact_unicode_bytes(self):
        path = self.csv('chinese', 'examples', [('示例,"e\u0301"', "shi'li", 0)])
        path.write_bytes(b'\xef\xbb\xbf' + path.read_bytes().replace(b'\n', b'\r\n'))
        self.build()
        self.assertEqual(self.query('chinese', "SELECT value,weight FROM tbl_2_s"), [('示例,"e\u0301"', 0)])

    def test_overlapping_categories_merge_max_weight_and_ignore_file_and_row_order(self):
        self.csv('chinese', 'words', [('讷', 'ne', 5), ('呢', 'ne', 10), ('呢', 'ne', 20)])
        self.csv('english', 'companies', [('Apple', 'apple', 20), ('Apple', 'apple', 5)])
        self.build()
        before = self.root / 'before.sqlite'
        target = self.output / 'Chinese/si-pinyin.sqlite'
        before.write_bytes(target.read_bytes())
        self.assertEqual(self.query('chinese', "SELECT value,weight FROM tbl_1_n WHERE key='ne' ORDER BY rowid"),
                         [('呢', 20), ('讷', 5)])
        self.assertEqual(self.query('english', "SELECT value,weight FROM tbl_1_a WHERE key='apple'"), [('Apple', 20)])
        # Moving rows, renaming categories and reordering duplicates must not select
        # a different winner or alter generated row IDs/tie order.
        self.csv('chinese', 'base', [('讷', 'ne', 5), ('内', 'nei', 5), ('你好', "ni'hao", 100)])
        (self.data / 'chinese/words.csv').unlink()
        self.csv('chinese', 'aaa', [('呢', 'ne', 20), ('讷', 'ne', 5), ('呢', 'ne', 10)])
        self.build()
        self.assertTrue(lexicon.same_dictionary(before, target))
        self.csv('chinese', 'aaa', [('呢', 'ne', 30), ('呢', 'ne', 10), ('讷', 'ne', 5)])
        self.build()
        self.assertEqual(self.query('chinese', "SELECT value,weight FROM tbl_1_n WHERE key='ne' AND value='呢'"),
                         [('呢', 30)])

    def test_distinct_readings_and_exact_unicode_outputs_are_not_merged(self):
        self.csv('chinese', 'examples', [('重', 'zhong', 10), ('重', 'chong', 20),
                                         ('é', 'li', 5), ('e\u0301', 'li', 5)])
        self.build()
        self.assertEqual(self.query('chinese', "SELECT key,value,weight FROM tbl_1_c WHERE value='重'"),
                         [('chong', '重', 20)])
        self.assertEqual(self.query('chinese', "SELECT key,value,weight FROM tbl_1_z WHERE value='重'"),
                         [('zhong', '重', 10)])
        self.assertEqual(self.query('chinese', "SELECT value FROM tbl_1_l WHERE key='li' ORDER BY rowid"),
                         [('e\u0301',), ('é',)])

    def test_bad_categories_preserve_every_existing_output(self):
        self.build()
        before = self.files()
        invalid = [[('apricot', 'apricot', -1)], [('apricot', 'apricot', 2**63)],
                   [('apricot', 'apricot', 'True')], [('apple', 'apple', 20)],
                   [('two words', 'two', 1)], [('café', 'café', 1)],
                   [('two words ', 'twowords', 1)], [('123', 'onetwothree', 1)],
                   [('apricot', 'ap', 1)], [('bad\ntext', 'bad', 1)], [('a', 'a')],
                   [('apricot', 'apricot', 1, 12)]]
        for entries in invalid:
            with self.subTest(entries=entries):
                path = self.csv('english', 'invalid', entries)
                with self.assertRaises(ValueError):
                    self.build()
                self.assertEqual(before, self.files())
                path.unlink()
        # A malformed second language cannot publish the staged first language.
        self.csv('chinese', 'new', [('新', 'xin', 12)])
        self.csv('english', 'invalid', [('bad', 'BAD', 1)])
        with self.assertRaises(ValueError):
            self.build()
        self.assertEqual(before, self.files())

    def test_english_titles_preserve_output_and_share_keys_with_ordinary_words(self):
        self.csv('english', 'base', [('soulmate', 'soulmate', 200)])
        self.csv('english', 'movie', [('Soul Mate', 'soulmate', 100),
                                     ('Inside Out 2', 'insideouttwo', 100),
                                     ("Don't Look Up", 'dontlookup', 100),
                                     ('WALL-E', 'walle', 100)])
        self.build()
        self.assertEqual(self.query('english', "SELECT key,value,weight FROM tbl_1_s ORDER BY rowid"),
                         [('soulmate', 'Soul Mate', 100), ('soulmate', 'soulmate', 200)])
        self.assertEqual(self.query('english', "SELECT value FROM tbl_1_i WHERE key='insideouttwo'"),
                         [('Inside Out 2',)])
        self.assertEqual(self.query('english', "SELECT value FROM tbl_1_d WHERE key='dontlookup'"),
                         [("Don't Look Up",)])
        self.build(check=True)
        before = self.files()
        self.csv('english', 'conflict', [('Soul mate', 'soulmate', 90)])
        with self.assertRaisesRegex(ValueError, 'casing'):
            self.build()
        self.assertEqual(before, self.files())

    def test_domains_use_literal_readings_and_invalid_updates_preserve_outputs(self):
        self.csv('english', 'domain', [('google.com', 'google.com', 100),
                                      ('rust-lang.org', 'rust-lang.org', 100),
                                      ('mail.163.com', 'mail.163.com', 100),
                                      ('163.com', '163.com', 100)])
        self.build()
        self.assertEqual(self.query('english', "SELECT key,value FROM tbl_1_g WHERE key='google.com'"),
                         [('google.com', 'google.com')])
        self.assertEqual(self.query('english', "SELECT value FROM tbl_1_c WHERE key='163.com'"), [('163.com',)])
        self.build(check=True)
        before = self.files()
        for text, reading in [('google.com', 'googlecom'), ('.ai', 'ai'),
                              ('Google.com', 'google.com'), ('host..com', 'hostcom'),
                              ('-host.com', 'host.com'), ('host.com/', 'hostcom')]:
            with self.subTest(text=text, reading=reading):
                self.csv('english', 'domain', [(text, reading, 100)])
                with self.assertRaises(ValueError):
                    self.build()
                self.assertEqual(before, self.files())
        with self.assertRaises(ValueError):
            lexicon.table_for('google.com')  # Dotted readings remain invalid for Chinese.

    def test_invalid_chinese_header_metadata_and_provenance_are_rejected(self):
        self.build()
        before = self.files()
        for entries in [[('例', 'li e', 1)], [('例', 'i', 1)], [('', 'li', 1)],
                        [('例' * 1366, 'li', 1)]]:
            path = self.csv('chinese', 'invalid', entries)
            with self.assertRaises(ValueError):
                self.build()
            path.unlink()
        path = self.data / 'english/base.csv'
        original = path.read_bytes()
        path.write_text('text,reading,weight,ordinal\nApple,apple,20,12\n')
        with self.assertRaisesRegex(ValueError, 'header'):
            self.build()
        path.write_bytes(original)
        self.meta['languages']['english']['unknown_weight'] = True
        self.save_meta()
        with self.assertRaisesRegex(ValueError, 'unknown weight'):
            self.build()
        self.meta['languages']['english']['unknown_weight'] = 9
        self.save_meta()
        (self.root / 'NOTICE').write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'Provenance checksum'):
            self.build()
        self.assertEqual(before, self.files())

    def test_inline_metadata_and_attribution_validation_preserve_outputs(self):
        self.build()
        before = self.files()
        upstream = self.meta['upstreams'][0]
        for invalid in ({}, None, 'removed/sources.lock.json'):
            upstream['metadata'] = invalid
            self.save_meta()
            with self.assertRaisesRegex(ValueError, 'inline object'):
                self.build()
            self.assertEqual(before, self.files())
        upstream['metadata'] = {'source': 'Synthetic fixture'}
        for invalid in ('../NOTICE', '/NOTICE'):
            upstream['attribution'] = invalid
            self.save_meta()
            with self.assertRaisesRegex(ValueError, 'inside the repository'):
                self.build()
            self.assertEqual(before, self.files())

    def test_check_detects_csv_manifest_and_database_changes_without_writes(self):
        self.build()
        before = self.files()
        self.csv('chinese', 'new', [('新', 'xin', 12)])
        with self.assertRaisesRegex(ValueError, 'out of date'):
            self.build(check=True)
        self.assertEqual(before, self.files())
        (self.data / 'chinese/new.csv').unlink()
        database = self.output / 'English/si-english.sqlite'
        manifest_path = database.parent / 'dictionary-manifest.json'
        # SQLite version headers can differ while schema, rows and indexes agree.
        raw = bytearray(database.read_bytes())
        raw[96:100] = (3040000).to_bytes(4, 'big')
        database.write_bytes(raw)
        manifest = json.loads(manifest_path.read_text())
        manifest['runtime_sha256'] = dictionary.digest(database.read_bytes())
        manifest_path.write_text(json.dumps(manifest))
        self.build(check=True)
        with sqlite3.connect(database) as connection:
            connection.execute('DROP INDEX idx_key_tbl_1_a')
        manifest['runtime_sha256'] = dictionary.digest(database.read_bytes())
        manifest_path.write_text(json.dumps(manifest))
        before = self.files()
        with self.assertRaisesRegex(ValueError, 'out of date'):
            self.build(check=True)
        self.assertEqual(before, self.files())


class LocalCategoryPolicyTests(unittest.TestCase):
    def test_checked_in_local_categories_use_ten_and_imported_files_have_no_prefix(self):
        data = Path(__file__).resolve().parents[2] / 'Data/Vocabulary'
        metadata = json.loads((data / 'meta.json').read_bytes())
        local_files = []
        for language in ('chinese', 'english'):
            upstream = set(metadata['upstream_categories'][language]) | {'base.csv'}
            for path in (data / language).glob('*.csv'):
                self.assertFalse(path.name.startswith('wanxiang_'))
                if path.name in upstream:
                    continue
                local_files.append(path)
                with path.open(newline='') as stream:
                    for row in csv.DictReader(stream):
                        self.assertEqual(row['weight'], '10', str(path))
        self.assertTrue(any(path.parent.name == 'chinese' for path in local_files))
        self.assertTrue(any(path.parent.name == 'english' for path in local_files))


if __name__ == '__main__':
    unittest.main()
