"""Synthetic Radar CSV imports, private token handling and failure-safe merging."""
import csv
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import urllib.error
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
import cloudflare_radar_domains as radar


class RadarDomainTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.patch = patch.object(radar, 'ROOT', self.root)
        self.patch.start()
        self.addCleanup(self.patch.stop)
        for relative, data in [(radar.CATEGORY, b'text,reading,weight\nsite0.example,site0.example,812\nlocal.example,local.example,55\n'),
                               (radar.METADATA, json.dumps({'upstreams': [], 'curations': [{'id': 'basic-domains', 'entries': 2}]}).encode()),
                               (radar.NOTICE, b'Synthetic attribution'), (radar.LICENSE, b'Synthetic license')]:
            target = self.root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        self.raw = ('domain\n' + ''.join(f'site{i}.example\n' for i in range(1000))).encode()
        self.input = self.root / 'input.csv'
        self.input.write_bytes(self.raw)

    def files(self):
        return {str(p.relative_to(self.root)): p.read_bytes() for p in self.root.rglob('*') if p.is_file()}

    def test_offline_merge_preserves_existing_values_and_replays_without_duplicates(self):
        original = (self.root / radar.CATEGORY).read_bytes()
        report = radar.update(input_path=self.input)
        self.assertEqual((report['fetched'], report['added'], report['overlap'], report['total_domains']), (1000, 999, 1, 1001))
        with (self.root / radar.CATEGORY).open() as stream:
            rows = list(csv.DictReader(stream))
        self.assertTrue(all(row['text'] == row['reading'] for row in rows))
        self.assertEqual(next(r['weight'] for r in rows if r['text'] == 'site0.example'), '812')
        self.assertEqual(next(r['weight'] for r in rows if r['text'] == 'local.example'), '55')
        self.assertTrue(all(r['weight'] == '10' for r in rows if r['text'] not in ('site0.example', 'local.example')))
        self.assertEqual((self.root / radar.SEED).read_bytes(), original)
        first_csv = (self.root / radar.CATEGORY).read_bytes()
        self.assertEqual(radar.update(input_path=self.input)['added'], 0)
        self.assertEqual((self.root / radar.CATEGORY).read_bytes(), first_csv)
        self.assertEqual((self.root / radar.SEED).read_bytes(), original)
        meta = json.loads((self.root / radar.METADATA).read_bytes())
        self.assertEqual(meta['domain_collection']['entries'], 1001)
        record = meta['upstreams'][0]
        self.assertFalse(record['metadata']['ordered'])
        self.assertEqual(record['metadata']['license'], 'CC-BY-NC-4.0')
        self.assertEqual(record['metadata']['snapshot_sha256'], radar.dictionary.digest(self.raw))

    def test_bad_remote_csv_never_changes_existing_sources(self):
        invalid = [b'{"success":false}', b'<html>Failure</html>', b'wrong\nsite.example\n',
                   b'domain\n.ai\n', b'domain\nUPPER.example\n', b'domain\nhttps://site.example\n',
                   self.raw.replace(b'site999.example', b'site0.example'),
                   self.raw.replace(b'site999.example\n', b''), b'domain\n\xff\n']
        for raw in invalid:
            with self.subTest(raw=raw[:40]):
                self.input.write_bytes(raw)
                before = self.files()
                with self.assertRaises(radar.ImportError):
                    radar.update(input_path=self.input)
                self.assertEqual(before, self.files())

    def test_intervening_source_edit_aborts_import(self):
        target = self.root / radar.CATEGORY
        changed = target.read_bytes() + b'new.example,new.example,75\n'
        def fetch(_token):
            target.write_bytes(changed)
            return self.raw, {}
        with patch.object(radar, 'read_token', return_value='synthetic-token'), patch.object(radar, 'fetch', side_effect=fetch):
            with self.assertRaisesRegex(radar.ImportError, 'changed during download'):
                radar.update()
        self.assertEqual(target.read_bytes(), changed)
        self.assertFalse((self.root / radar.SNAPSHOT).exists())

    def test_publish_failure_rolls_back_all_already_replaced_files(self):
        before = self.files()
        replace = os.replace
        calls = 0
        def fail_second(source, target):
            nonlocal calls
            calls += 1
            if calls == 2:
                raise OSError('Synthetic disk failure')
            return replace(source, target)
        with patch.object(radar.os, 'replace', side_effect=fail_second):
            with self.assertRaises(OSError):
                radar.update(input_path=self.input)
        self.assertEqual(before, self.files())

    def test_dotenv_is_parsed_as_data_and_token_stays_out_of_saved_metadata(self):
        env_file = self.root / '.env'
        env_file.write_text('IGNORED=$(touch never)\nexport CLOUDFLARE_RADAR_API_TOKEN="synthetic-secret"\n')
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(radar.read_token(env_file), 'synthetic-secret')
            with patch.object(radar, 'fetch', return_value=(self.raw, {'ETag': 'public-etag'})) as fetch:
                radar.update(env_file=env_file)
            self.assertEqual(fetch.call_args.args, ('synthetic-secret',))
        self.assertFalse((self.root / 'never').exists())
        for relative in (radar.METADATA, radar.CATEGORY, radar.SNAPSHOT):
            self.assertNotIn(b'synthetic-secret', (self.root / relative).read_bytes())

    def test_missing_token_and_redirect_fail_without_printing_credential(self):
        with patch.dict(os.environ, {}, clear=True):
            with self.assertRaisesRegex(radar.ImportError, 'Set CLOUDFLARE_RADAR_API_TOKEN'):
                radar.read_token(self.root / 'absent.env')
        with self.assertRaisesRegex(radar.ImportError, 'no credential was forwarded'):
            radar.NoRedirect().redirect_request(None, None, 302, '', {}, 'https://other.example')

    def test_authentication_failure_does_not_expose_request_token_or_response(self):
        class FailingOpener:
            def open(self, request, timeout):
                raise urllib.error.HTTPError(request.full_url, 403, 'synthetic-secret', {}, None)
        with patch.object(radar.urllib.request, 'build_opener', return_value=FailingOpener()):
            with self.assertRaises(radar.ImportError) as raised:
                radar.fetch('synthetic-secret')
        self.assertIn('HTTP 403', str(raised.exception))
        self.assertIn('Radar Read', str(raised.exception))
        self.assertNotIn('synthetic-secret', str(raised.exception))


if __name__ == '__main__':
    unittest.main()
