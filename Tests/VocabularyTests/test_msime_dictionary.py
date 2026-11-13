"""Small public fixtures for the sole Chinese dictionary maintenance pipeline."""
import csv
import io
import json
from pathlib import Path
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
        self.data.mkdir()
        self.patch = patch.object(dictionary, 'METADATA', self.data / 'meta.json')
        self.patch.start()
        self.addCleanup(self.patch.stop)

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
        saw_extension = False
        for path in sorted((dictionary.ROOT / 'Data/Chinese').glob('*.csv')):
            with path.open(encoding='utf-8-sig', newline='') as stream:
                for row in csv.DictReader(stream):
                    text = row['text']
                    if any(unicodedata.category(character) == 'Co' for character in text):
                        self.fail(f'Private-use entry: {row["reading"]} {ascii(text)}')
                    saw_extension |= row['reading'] == 'biang' and text == '\U00030ede'
        self.assertTrue(saw_extension)


if __name__ == '__main__':
    unittest.main()
