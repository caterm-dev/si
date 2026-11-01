"""Public domain vocabulary syntax, representative coverage and provenance."""
import csv
import hashlib
import json
from pathlib import Path
import re
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
import csv_dictionary as dictionary


class DomainVocabularyTests(unittest.TestCase):
    def test_domain_category_is_valid_ascii_without_urls_or_duplicate_outputs(self):
        path = ROOT / 'Data/Vocabulary/english/domain.csv'
        with path.open() as stream:
            reader = csv.DictReader(stream)
            self.assertEqual(reader.fieldnames, ['text', 'reading', 'weight'])
            rows = list(reader)
        self.assertEqual(len({r['text'] for r in rows}), len(rows))
        label = r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?'
        for row in rows:
            with self.subTest(domain=row['text']):
                text = row['text']
                self.assertIsNotNone(re.fullmatch(label + r'(?:\.' + label + r')+', text))
                self.assertFalse(text.startswith('.'))
                self.assertIn('.', text)
                self.assertEqual(row['reading'], text)
                self.assertLessEqual(len(text.lstrip('.')), 253)
                self.assertEqual(row['reading'], dictionary.english_reading(text))
                self.assertEqual(int(row['weight']), 10)
        meta = json.loads((ROOT / 'Data/Vocabulary/meta.json').read_text())
        curation = next(r for r in meta['curations'] if r['id'] == 'basic-domains')
        seed = ROOT / curation['catalog']
        self.assertEqual(curation['catalog_sha256'], hashlib.sha256(seed.read_bytes()).hexdigest())
        if 'domain_collection' in meta:
            self.assertEqual(meta['domain_collection']['entries'], len(rows))
            self.assertEqual(meta['domain_collection']['sha256'], hashlib.sha256(path.read_bytes()).hexdigest())
        else:
            self.assertEqual(curation['entries'], len(rows))
        for source in meta['upstreams']:
            if source['id'] != 'cloudflare-radar-top-1000':
                continue
            record = source['metadata']
            for name, checksum in [(source['attribution'], source['attribution_sha256']),
                                   (record['license_file'], record['license_sha256']),
                                   (record['snapshot'], record['snapshot_sha256'])]:
                self.assertEqual(hashlib.sha256((ROOT / name).read_bytes()).hexdigest(), checksum)
            self.assertEqual(record['license'], 'CC-BY-NC-4.0')
            self.assertFalse(record['ordered'])

    def test_full_service_names_remain_covered_without_standalone_suffixes(self):
        with (ROOT / 'Data/Vocabulary/english/domain.csv').open() as stream:
            texts = {row['text'] for row in csv.DictReader(stream)}
        required = {'google.com', 'bing.com',
                    'baidu.com', 'wikipedia.org', 'github.com', 'python.org', 'rust-lang.org',
                    'cloudflare.com', 'docs.google.com', 'gmail.com', 'mail.163.com',
                    'bilibili.com', 'apple.com', 'example.com', 'example.org', 'example.net'}
        self.assertTrue(required <= texts)
        self.assertFalse(any(text.startswith('.') for text in texts))


if __name__ == '__main__':
    unittest.main()
