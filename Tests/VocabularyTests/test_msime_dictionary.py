"""Small public fixtures for the sole Chinese dictionary maintenance pipeline."""
import contextlib
import io
import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import unicodedata
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
import msime_dictionary as dictionary


class MSIMEDictionaryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.data = root / 'source'
        self.output = root / 'output'
        self.data.mkdir()
        self.patch = patch.multiple(dictionary, DATA=self.data, RESOURCES=self.output, METADATA=self.data / 'meta.json')
        self.patch.start()
        self.addCleanup(self.patch.stop)

    def test_context_check_rejects_tampering_without_downloading(self):
        self.output.mkdir()
        content = b'Synthetic context fixture'
        target = self.output / 'msime-bigram.bin'
        target.write_bytes(content)
        (self.data / 'resources.lock.json').write_text(json.dumps(dict(artifacts=[dict(
            name=target.name, size=len(content), sha256=dictionary.digest(content))])))
        with contextlib.redirect_stdout(io.StringIO()), patch.object(dictionary.urllib.request, 'urlopen') as network:
            dictionary.verify_context()
            target.write_bytes(content + b'changed')
            with self.assertRaisesRegex(ValueError, 'Context checksum mismatch'):
                dictionary.verify_context()
            network.assert_not_called()

    def test_audit_reports_revisions_without_changing_sources(self):
        lock_path = self.data / 'meta.json'
        lock = {}
        for kind in ('dictionary', 'engine'):
            lock[kind + '_repository'] = 'https://github.com/metasequoiaime/msime' + ('-dictionary' if kind == 'dictionary' else '')
            lock[kind + '_revision'] = '1' * 40
        lock_path.write_text(json.dumps({'upstreams': [{'id': 'chinese-bootstrap', 'metadata': lock}]}))
        before = lock_path.read_bytes()
        responses = [io.BytesIO(json.dumps(dict(sha=revision)).encode()) for revision in ['2' * 40, '1' * 40]]
        with patch.object(dictionary.urllib.request, 'urlopen', side_effect=responses):
            report = dictionary.audit()
        self.assertEqual([row['update_available'] for row in report['sources']], [True, False])
        self.assertTrue(report['sources'][0]['compare_url'].endswith('1' * 40 + '...' + '2' * 40))
        self.assertEqual(lock_path.read_bytes(), before)


class BundledChineseDictionaryTests(unittest.TestCase):
    def test_no_private_use_characters_without_removing_unicode_han_extensions(self):
        database = dictionary.ROOT / 'mac/SI/Core/Resources/Chinese/si-pinyin.sqlite'
        with sqlite3.connect(database.resolve().as_uri() + '?mode=ro&immutable=1', uri=True) as connection:
            tables = [row[0] for row in connection.execute(
                "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'tbl_%'")]
            self.assertTrue(tables)
            for table in tables:
                for reading, text in connection.execute(f'SELECT key,value FROM {table}'):
                    if any(unicodedata.category(character) == 'Co' for character in text):
                        self.fail(f'Bundled private-use entry: {reading} {ascii(text)}')
            self.assertIsNotNone(connection.execute(
                "SELECT 1 FROM tbl_1_b WHERE key='biang' AND value=?", ('\U00030ede',)).fetchone())


if __name__ == '__main__':
    unittest.main()
