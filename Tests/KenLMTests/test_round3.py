import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
import kenlm_round3 as r


class Round3Tests(unittest.TestCase):
    def test_streamed_versions_share_frozen_train_rules_and_preserve_sources(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            old = root / 'old'
            data = old / 'data'
            data.mkdir(parents=True)
            (data / 'train.txt').write_text('词典 1 新词\n' * 4 + '词典 2 新词 �\n' +
                                           '边界 3.5\n' * 5 + 'x' * 33 + ' 99\n')
            (data / 'heldout.txt').write_text('新词 词典 8\n' * 25 + '坏 锟斤拷\n')
            splits = {}
            before = {}
            for name in ('train', 'heldout'):
                path = data / (name + '.txt')
                raw = path.read_bytes()
                splits[name] = {'sha256': hashlib.sha256(raw).hexdigest(),
                                'lines': len(raw.splitlines()), 'tokens': len(raw.split())}
                before[name] = (raw, path.stat().st_mtime_ns, path.stat().st_ino)
            (data / 'manifest.json').write_text(json.dumps({'splits': splits}))
            out = root / 'new'
            with patch.object(r, 'ORIGINAL', data), patch.object(r.previous, 'OLD', old), \
                 patch.object(r, 'dictionary_sources', return_value=[]), \
                 patch.object(r, 'dictionary_words', return_value={'词典'}):
                r.prepare(out)
                r.prepare(out)
            manifest = json.loads((out / 'data/manifest.json').read_text())['versions']
            for version in r.VERSIONS:
                self.assertEqual(manifest[version]['train']['deleted_garbled_lines'], 1)
                self.assertEqual(manifest[version]['train']['retained_tokens'], 24)
                self.assertEqual(manifest[version]['train']['replaced_num_tokens'], 10)
                self.assertEqual(manifest[version]['heldout']['output_lines'], 25)
            self.assertEqual(manifest['clean1']['train']['replaced_oov_tokens'], 1)
            self.assertEqual(manifest['clean2']['train']['replaced_oov_tokens'], 5)
            self.assertEqual(manifest['clean3']['train']['replaced_oov_tokens'], 10)
            self.assertEqual((out / 'data/clean2/heldout.txt').read_text(), '<oov> 词典 <num>\n' * 25)
            self.assertEqual((out / 'data/clean1/heldout.txt').read_text(), '新词 词典 <num>\n' * 25)
            for name in ('train', 'heldout'):
                path = data / (name + '.txt')
                self.assertEqual(before[name], (path.read_bytes(), path.stat().st_mtime_ns, path.stat().st_ino))


if __name__ == '__main__':unittest.main()
