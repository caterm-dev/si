"""Count CSV compilation, normalized log10 metadata and atomic failure checks."""
import contextlib
import csv
from datetime import datetime
import io
import math
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
        self.data = self.root / 'Data'
        self.output = self.root / 'output'
        for language in dictionary.DATABASES:
            (self.data / language.title()).mkdir(parents=True)
        patches = patch.multiple(dictionary, DATA=self.data, RESOURCES=self.output)
        patches.start()
        self.addCleanup(patches.stop)
        self.csv('chinese', 'base', [('呢', 'ne', 20), ('讷', 'ne', 5), ('你好', "ni'hao", 75)])
        self.csv('english', 'base', [('Apple', 'apple', 20), ('alpha', 'alpha', 5)])

    def csv(self, language, category, rows):
        path = self.data / language.title() / (category + '.csv')
        with path.open('w', encoding='utf-8', newline='') as stream:
            writer = csv.writer(stream, lineterminator='\n')
            writer.writerow(dictionary.COLUMNS)
            writer.writerows(rows)
        return path

    def build(self, check=False, **kwargs):
        with contextlib.redirect_stdout(io.StringIO()):
            dictionary.build(check=check, **kwargs)

    def query(self, language, sql):
        path = self.output / language.title() / dictionary.DATABASES[language]
        with sqlite3.connect(path) as connection:
            return connection.execute(sql).fetchall()

    def files(self):
        return {str(p.relative_to(self.output)): (p.read_bytes(), p.stat().st_mtime_ns)
                for p in self.output.rglob('*') if p.is_file()}

    def test_probabilities_metadata_and_independent_language_totals(self):
        self.build()
        for language, total in [('chinese', 100), ('english', 25)]:
            meta = dict(self.query(language, 'SELECT key,value FROM meta'))
            self.assertEqual(int(meta['total_n']), total)
            self.assertEqual(meta['log_base'], 'log10')
            self.assertEqual(meta['schema_version'], '2')
            self.assertAlmostEqual(float(meta['unk_logp']), math.log10(0.5 / total))
            self.assertTrue(meta['corpus_version'].startswith('sha256:'))
            self.assertIsNotNone(datetime.fromisoformat(meta['built_at']).utcoffset())
            self.assertEqual(self.query(language, 'PRAGMA integrity_check'), [('ok',)])
        rows = self.query('chinese', 'SELECT key,jp,value,weight,typeof(weight) FROM tbl_1_n ORDER BY weight DESC,rowid')
        self.assertEqual([row[:3] for row in rows], [('ne', 'n', '呢'), ('ne', 'n', '讷')])
        for row, count in zip(rows, [20, 5]):
            self.assertEqual(row[4], 'real')
            self.assertAlmostEqual(row[3], math.log10(count / 100))

    def test_duplicates_sum_and_distinct_readings_and_casing_survive(self):
        self.csv('chinese', 'extra', [('呢', 'ne', 30), ('呢', 'ne', 10), ('呢', 'ni', 40)])
        self.csv('english', 'extra', [('Apple', 'apple', 5), ('apple', 'apple', 10)])
        self.build()
        self.assertEqual(dict(self.query('chinese', 'SELECT key,value FROM meta'))['total_n'], '180')
        self.assertAlmostEqual(self.query('chinese', "SELECT weight FROM tbl_1_n WHERE key='ne' AND value='呢'")[0][0],
                               math.log10(60 / 180))
        self.assertEqual(self.query('chinese', "SELECT count(*) FROM tbl_1_n WHERE value='呢'"), [(2,)])
        self.assertEqual(self.query('english', 'SELECT value FROM tbl_1_a ORDER BY rowid'), [('alpha',), ('Apple',), ('apple',)])

    def test_zero_uses_stored_unknown_floor_without_changing_total(self):
        self.csv('chinese', 'zero', [('零', 'ling', 0)])
        self.build()
        meta = dict(self.query('chinese', 'SELECT key,value FROM meta'))
        self.assertEqual(meta['total_n'], '100')
        self.assertEqual(self.query('chinese', 'SELECT weight FROM tbl_1_l')[0][0], float(meta['unk_logp']))

    def test_check_is_read_only_and_semantic_comparison_ignores_build_time_only(self):
        self.build()
        before = self.files()
        self.build(check=True)
        self.assertEqual(before, self.files())
        path = self.output / 'Chinese/si-pinyin.sqlite'
        copy = self.root / 'copy.sqlite'
        copy.write_bytes(path.read_bytes())
        with sqlite3.connect(copy) as connection:
            connection.execute("UPDATE meta SET value='2000-01-01T00:00:00+00:00' WHERE key='built_at'")
        self.assertTrue(lexicon.same_dictionary(copy, path))
        with sqlite3.connect(copy) as connection:
            connection.execute("UPDATE meta SET value='-99' WHERE key='unk_logp'")
        self.assertFalse(lexicon.same_dictionary(copy, path))

    def test_explicit_version_and_stale_csv_detection(self):
        self.build(corpus_version='synthetic-v1')
        self.assertEqual(dict(self.query('english', 'SELECT key,value FROM meta'))['corpus_version'], 'synthetic-v1')
        self.build(check=True, corpus_version='synthetic-v1')
        before = self.files()
        self.csv('english', 'base', [('Apple', 'apple', 200)])
        with self.assertRaisesRegex(ValueError, 'out of date'):
            self.build(check=True, corpus_version='synthetic-v1')
        self.assertEqual(before, self.files())

    def test_invalid_second_language_never_publishes_first_language(self):
        self.build()
        before = self.files()
        for bad_count in ['', '-1', '1.5', str(2**63)]:
            self.csv('english', 'base', [('Apple', 'apple', bad_count)])
            with self.subTest(count=bad_count), self.assertRaisesRegex(ValueError, 'count'):
                self.build()
            self.assertEqual(before, self.files())
        self.csv('english', 'base', [('Apple', 'apple', 0)])
        with self.assertRaisesRegex(ValueError, 'Total count'):
            self.build()
        self.assertEqual(before, self.files())

    def test_unicode_and_csv_quoting_preserve_exact_output(self):
        path = self.csv('chinese', 'custom', [('示例,"e\u0301"', "shi'li", 1)])
        path.write_bytes(b'\xef\xbb\xbf' + path.read_bytes().replace(b'\n', b'\r\n'))
        self.build()
        self.assertEqual(self.query('chinese', 'SELECT value FROM tbl_2_s'), [('示例,"e\u0301"',)])

    def test_merged_count_and_total_overflow_preserve_outputs(self):
        self.build()
        before = self.files()
        self.csv('english', 'base', [('Apple', 'apple', 2**63 - 1)])
        self.csv('english', 'extra', [('Apple', 'apple', 1)])
        with self.assertRaisesRegex(ValueError, 'Merged count'):
            self.build()
        self.assertEqual(before, self.files())
        self.csv('english', 'extra', [('alpha', 'alpha', 1)])
        with self.assertRaisesRegex(ValueError, 'Total count'):
            self.build()
        self.assertEqual(before, self.files())


if __name__ == '__main__':
    unittest.main()
