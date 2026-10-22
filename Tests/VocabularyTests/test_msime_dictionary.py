"""Small public fixtures for the sole Chinese dictionary maintenance pipeline."""
import contextlib
import gzip
import io
import json
from pathlib import Path
import sqlite3
import sys
import tempfile
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
        self.patch = patch.multiple(dictionary, DATA=self.data, RESOURCES=self.output)
        self.patch.start()
        self.addCleanup(self.patch.stop)
        records = []
        for index, (upstream, content) in enumerate([
            ('sources/pinyin/single-chars.txt', '呢\tne\t10\n内\tne\t5\n'),
            ('sources/pinyin/rime-ice.txt', '呢\tne\t20\n讷\tne\t5\n'),
            ('custom/words.txt', '内\tne\t5\n'),
        ]):
            raw = content.encode()
            name = f'{index}.gz'
            (self.data / name).write_bytes(gzip.compress(raw, mtime=0))
            records.append(dict(path=name, upstream_path=upstream, size=len(raw), sha256=dictionary.digest(raw)))
        (self.data / 'reading-corrections.tsv').write_bytes(b'')
        (self.data / 'sources.lock.json').write_text(json.dumps(dict(
            schema_version=1, sources=records, corrections_sha256=dictionary.digest(b''))))
        self.overlay([])

    def overlay(self, entries):
        (self.data / 'si-entries.json').write_text(json.dumps(entries, ensure_ascii=False))

    def build(self, check=False):
        with contextlib.redirect_stdout(io.StringIO()):
            dictionary.build(check)

    def test_deduplication_ties_overlay_and_reproducible_check(self):
        self.overlay([
            dict(text='内', reading='ne', exclude=True, reason='Synthetic exclusion'),
            dict(text='哪', reading='ne', weight=5, reason='Synthetic addition'),
        ])
        self.build()
        database = self.output / 'si-pinyin.sqlite'
        with sqlite3.connect(database) as connection:
            rows = connection.execute('SELECT value,weight FROM tbl_1_n ORDER BY weight DESC,rowid').fetchall()
            self.assertEqual(rows, [('呢', 20), ('讷', 5), ('哪', 5)])
            self.assertEqual(connection.execute('PRAGMA integrity_check').fetchone(), ('ok',))
        before = {p.name: (p.read_bytes(), p.stat().st_mtime_ns) for p in self.output.iterdir()}
        self.build(check=True)
        self.assertEqual(before, {p.name: (p.read_bytes(), p.stat().st_mtime_ns) for p in self.output.iterdir()})
        self.overlay([])
        with self.assertRaisesRegex(ValueError, 'out of date'):
            self.build(check=True)
        self.assertEqual(before, {p.name: (p.read_bytes(), p.stat().st_mtime_ns) for p in self.output.iterdir()})

    def test_checksum_failure_preserves_generated_files(self):
        self.build()
        before = {p.name: p.read_bytes() for p in self.output.iterdir()}
        (self.data / '0.gz').write_bytes(gzip.compress(b'changed', mtime=0))
        with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
            self.build()
        self.assertEqual(before, {p.name: p.read_bytes() for p in self.output.iterdir()})

    def test_check_accepts_sqlite_version_headers_but_rejects_missing_indexes(self):
        self.build()
        database = self.output / 'si-pinyin.sqlite'
        manifest = self.output / 'dictionary-manifest.json'

        def update_hash():
            value = json.loads(manifest.read_text())
            value['runtime_sha256'] = dictionary.digest(database.read_bytes())
            manifest.write_text(json.dumps(value))

        raw = bytearray(database.read_bytes())
        raw[96:100] = (3040000).to_bytes(4, 'big')
        database.write_bytes(raw)
        update_hash()
        self.build(check=True)
        with sqlite3.connect(database) as connection:
            connection.execute('DROP INDEX idx_key_tbl_1_n')
        update_hash()
        with self.assertRaisesRegex(ValueError, 'out of date'):
            self.build(check=True)

    def test_invalid_local_changes_are_rejected(self):
        valid = dict(text='呢', reading='ne', weight=20, reason='Synthetic fixture')
        cases = [
            [valid, valid], [dict(valid, weight=True)], [dict(valid, exclude=True)],
            [dict(valid, reason=' ')], [dict(valid, reading='n e')],
            [dict(valid, text='a\nb')], [dict(valid, weight=-1)],
            [dict(valid, exclude='true')], [dict(valid, unexpected=1)],
        ]
        for entries in cases:
            with self.subTest(entries=entries):
                self.overlay(entries)
                with self.assertRaises(ValueError):
                    self.build()
                self.assertFalse((self.output / 'si-pinyin.sqlite').exists())

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
        lock_path = self.data / 'sources.lock.json'
        lock = json.loads(lock_path.read_text())
        for kind in ('dictionary', 'engine'):
            lock[kind + '_repository'] = 'https://github.com/metasequoiaime/msime' + ('-dictionary' if kind == 'dictionary' else '')
            lock[kind + '_revision'] = '1' * 40
        lock_path.write_text(json.dumps(lock))
        before = lock_path.read_bytes()
        responses = [io.BytesIO(json.dumps(dict(sha=revision)).encode()) for revision in ['2' * 40, '1' * 40]]
        with patch.object(dictionary.urllib.request, 'urlopen', side_effect=responses):
            report = dictionary.audit()
        self.assertEqual([row['update_available'] for row in report['sources']], [True, False])
        self.assertTrue(report['sources'][0]['compare_url'].endswith('1' * 40 + '...' + '2' * 40))
        self.assertEqual(lock_path.read_bytes(), before)


if __name__ == '__main__':
    unittest.main()
