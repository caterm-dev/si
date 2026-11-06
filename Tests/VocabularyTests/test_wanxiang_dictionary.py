"""Synthetic import safety plus exact pinned-source/base/resource consistency."""
import contextlib
import csv
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
import csv_dictionary as dictionary
import wanxiang_dictionary as importer


class WanxiangConversionTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.data = self.root / 'Data/Vocabulary'
        self.sources = self.root / 'upstream'
        self.lock = {'schema_version': 1, 'repository': 'https://github.com/amzxyz/rime-wanxiang-data',
                     'revision': 'a' * 40, 'category_overlap': 'base', 'files': []}
        for language in ('chinese', 'english'):
            (self.data / language).mkdir(parents=True)
            (self.data / language / 'base.csv').write_text('text,reading,weight\nold,old,900\n')
        self.notice = self.root / 'mac/SI/Core/Resources/English/Wanxiang-NOTICE.txt'
        self.notice.parent.mkdir(parents=True)
        self.notice.write_text('Synthetic notice')
        (self.data / 'meta.json').write_text(json.dumps({'schema_version': 2,
            'dictionary_format': dictionary.lexicon.FORMAT,
            'languages': {'chinese': {'unknown_weight': 1}, 'english': {'unknown_weight': 9}},
            'upstreams': []}))
        patches = patch.multiple(importer, ROOT=self.root, DATA=self.data,
                                 PROVENANCE=self.data / 'Wanxiang')
        patches.start()
        self.addCleanup(patches.stop)
        self.patch_dictionary = patch.object(dictionary, 'DATA', self.data)
        self.patch_dictionary.start()
        self.addCleanup(self.patch_dictionary.stop)

    def source(self, name, language, body):
        path = 'dicts/' + name + '.dict.yaml'
        data = ('# Synthetic dictionary\n---\nname: ' + name + '\nsort: by_weight\n...\n' + body).encode()
        target = self.sources / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        self.lock['files'].append({'path': path, 'language': language,
                                   'size': len(data), 'sha256': dictionary.digest(data)})
        return target

    def minimal(self):
        self.source('zi', 'chinese', '不\tbù\t575\n')
        self.source('en', 'english', 'but\tbut\t427\n')

    def run_conversion(self, check=False):
        with contextlib.redirect_stdout(io.StringIO()):
            importer.convert(self.sources, self.lock, check)

    def snapshot(self):
        return {str(p.relative_to(self.data)): p.read_bytes()
                for p in self.data.rglob('*') if p.is_file()}

    def test_tones_umlaut_readings_and_exact_outputs_keep_unscaled_weights(self):
        self.source('zi', 'chinese', '绿\tlǜ\t575\n女\tnǚ\t12\n不\tbù\t50\n不\tbú\t60\n')
        self.source('duoyin', 'chinese', '不\tbù\t55\n绿\tlu\u0308\u0300\t570\n吕\tlǚ\n例\tlì\t6N\n')
        self.source('en', 'english', "but\tbut\t427\nDon't Panic!\tdontpanic\t8\nChatGPT\tChatGPT\t16\n")
        outputs, report = importer.convert_sources(self.sources, self.lock)
        rows = list(csv.DictReader(io.StringIO(outputs['chinese/base.csv'].decode())))
        self.assertEqual({(r['text'], r['reading']): int(r['weight']) for r in rows},
                         {('绿', 'lv'): 575, ('女', 'nv'): 12, ('不', 'bu'): 60, ('吕', 'lv'): 0, ('例', 'li'): 6})
        english = list(csv.DictReader(io.StringIO(outputs['english/base.csv'].decode())))
        self.assertIn({'text': "Don't Panic!", 'reading': 'dontpanic', 'weight': '8'}, english)
        self.assertEqual(report['sources'][1]['missing_weight'], 1)
        self.assertEqual(report['sources'][1]['numeric_weight_suffix'], 1)

    def test_english_casing_collisions_and_unsupported_forms_are_explicit(self):
        self.source('zi', 'chinese', '不\tbù\t575\n\ue000\tbù\t999\n')
        self.source('en', 'english', 'swift\tswift\t40\nSwift\tSwift\t50\nSWIFT\tSWIFT\t50\n'
                    'café\tcafe\t70\n123\t123\t90\nLinus Torvalds\tLinusTorvalds\n')
        outputs, report = importer.convert_sources(self.sources, self.lock)
        english = list(csv.DictReader(io.StringIO(outputs['english/base.csv'].decode())))
        self.assertIn({'text': 'Swift', 'reading': 'swift', 'weight': '50'}, english)
        self.assertEqual(len(english), 2)
        self.assertEqual(report['sources'][0]['excluded_private_use'], 1)
        self.assertEqual(report['sources'][1]['excluded_unsupported_english'], 2)
        self.assertEqual(report['sources'][1]['merged_duplicate'], 2)

    def test_categories_are_unchanged_and_base_owns_overlap_weight_and_casing(self):
        self.minimal()
        self.source('extra', 'english', 'Soul\tSoul\t30\n')
        category = self.data / 'english/movie.csv'
        category.write_text('text,reading,weight\nsoul,soul,9000\nInside Out,insideout,100\n')
        chinese = self.data / 'chinese/movie.csv'
        chinese.write_text('text,reading,weight\n不,bu,9000\n新,xin,100\n')
        originals = {p: p.read_bytes() for p in (category, chinese)}
        self.run_conversion()
        for path, content in originals.items():
            self.assertEqual(path.read_bytes(), content)
        self.assertEqual({(t, r): w for t, r, w in dictionary.rows('english')[0]},
                         {('but', 'but'): 427, ('Soul', 'soul'): 30, ('Inside Out', 'insideout'): 100})
        self.assertEqual({(t, r): w for t, r, w in dictionary.rows('chinese')[0]},
                         {('不', 'bu'): 575, ('新', 'xin'): 100})
        before = self.snapshot()
        self.run_conversion(check=True)
        self.assertEqual(before, self.snapshot())

    def test_english_editorial_exclusion_does_not_remove_the_chinese_reading(self):
        self.source('zi', 'chinese', '我来\twǒ lái\t575\n')
        self.source('en', 'english', 'but\tbut\t427\nwolai\twolai\t1\nWolai\tWolai\t2\n')
        self.run_conversion()
        self.assertEqual(dictionary.rows('english')[0], [('but', 'but', 427)])
        self.assertEqual(dictionary.rows('chinese')[0], [('我来', "wo'lai", 575)])
        report = json.loads((self.data / 'Wanxiang/conversion-report.json').read_bytes())
        self.assertEqual(report['sources'][1]['excluded_editorial_english'], 2)
        self.assertEqual([row['text'] for row in report['sources'][1]['exclusions']], ['wolai', 'Wolai'])
        self.run_conversion(check=True)

    def test_checksum_invalid_reading_or_malformed_second_language_preserve_outputs(self):
        cases = [('不\tbù\t575\n', 'but\tbut\t-1\n'),
                 ('不\tbù\t575\n', 'but\tbut\t9223372036854775808\n'),
                 ('不\tbu!\t575\n', 'but\tbut\t427\n'),
                 ('不\tbù\t575\n', 'but\n')]
        for zh, en in cases:
            with self.subTest(en=en, zh=zh):
                self.lock['files'] = []
                self.source('zi', 'chinese', zh)
                self.source('en', 'english', en)
                before = self.snapshot()
                with self.assertRaises(ValueError):
                    self.run_conversion()
                self.assertEqual(before, self.snapshot())
        self.lock['files'] = []
        self.minimal()
        (self.sources / 'dicts/en.dict.yaml').write_text('changed')
        before = self.snapshot()
        with self.assertRaisesRegex(ValueError, 'checksum'):
            self.run_conversion()
        self.assertEqual(before, self.snapshot())

    def test_no_network_for_conversion_and_check_detects_edited_base(self):
        self.minimal()
        with patch.object(importer.urllib.request, 'urlopen') as network:
            self.run_conversion()
            network.assert_not_called()
        path = self.data / 'english/base.csv'
        path.write_text(path.read_text().replace('427', '428'))
        before = self.snapshot()
        with self.assertRaisesRegex(ValueError, 'out of date'):
            self.run_conversion(check=True)
        self.assertEqual(before, self.snapshot())

    def test_upstream_categories_keep_their_files_and_weights_over_legacy_copies(self):
        self.minimal()
        self.source('diming', 'chinese', '新城\txīn chéng\t7\n不\tbù\t999\n')
        self.lock['files'][-1]['category'] = 'wanxiang_diming'
        legacy = self.data / 'chinese/geography.csv'
        legacy.write_text("text,reading,weight\n新城,xin'cheng,9000\n旧城,jiu'cheng,12\n")
        original = legacy.read_bytes()
        self.run_conversion()
        self.assertEqual(legacy.read_bytes(), original)
        imported = self.data / 'chinese/wanxiang_diming.csv'
        self.assertIn("新城,xin'cheng,7", imported.read_text())
        effective = {(t, r): w for t, r, w in dictionary.rows('chinese')[0]}
        self.assertEqual(effective[('新城', "xin'cheng")], 7)
        self.assertEqual(effective[('旧城', "jiu'cheng")], 12)
        self.assertEqual(effective[('不', 'bu')], 575)
        before = self.snapshot()
        self.run_conversion(check=True)
        self.assertEqual(before, self.snapshot())

    def test_fetch_verifies_existing_cache_without_network_and_rejects_tampering(self):
        self.minimal()
        with patch.object(importer.urllib.request, 'urlopen') as network:
            with contextlib.redirect_stdout(io.StringIO()):
                importer.fetch(self.sources, self.lock)
            network.assert_not_called()
            path = self.sources / self.lock['files'][0]['path']
            path.write_text('tampered')
            with self.assertRaisesRegex(ValueError, 'checksum'):
                importer.fetch(self.sources, self.lock)
            self.assertEqual(path.read_text(), 'tampered')

    def test_retired_import_category_is_removed_but_local_edits_are_protected(self):
        self.minimal()
        self.source('diming', 'chinese', '新城\txīn chéng\t7\n')
        self.lock['files'][-1]['category'] = 'wanxiang_diming'
        self.run_conversion()
        category = self.data / 'chinese/wanxiang_diming.csv'
        original = category.read_bytes()
        self.lock['files'].pop()
        category.write_bytes(original + b'local,xin,99\n')
        before = self.snapshot()
        with self.assertRaisesRegex(ValueError, 'local edits'):
            self.run_conversion()
        self.assertEqual(before, self.snapshot())
        category.write_bytes(original)
        self.run_conversion()
        self.assertFalse(category.exists())
        self.run_conversion(check=True)

    def test_import_category_prefix_removal_preserves_weights_and_retires_old_filename(self):
        self.minimal()
        self.source('diming', 'chinese', '新城\txīn chéng\t7\n')
        self.lock['files'][-1]['category'] = 'wanxiang_diming'
        self.run_conversion()
        old = self.data / 'chinese/wanxiang_diming.csv'
        expected = old.read_bytes()
        self.lock['files'][-1]['category'] = 'diming'
        self.run_conversion()
        self.assertFalse(old.exists())
        self.assertEqual((self.data / 'chinese/diming.csv').read_bytes(), expected)
        meta = json.loads((self.data / 'meta.json').read_bytes())
        self.assertEqual(meta['upstream_categories']['chinese'], ['diming.csv'])
        self.run_conversion(check=True)

    def test_publication_failure_rolls_back_both_bases_and_metadata(self):
        self.minimal()
        before = self.snapshot()
        original = dictionary.write_atomic
        calls = 0

        def fail_once(path, data):
            nonlocal calls
            calls += 1
            if calls == 2:
                raise OSError('Synthetic publication failure')
            original(path, data)

        with patch.object(dictionary, 'write_atomic', side_effect=fail_once):
            with self.assertRaisesRegex(OSError, 'publication failure'):
                self.run_conversion()
        self.assertEqual(before, self.snapshot())

    def test_failure_after_replacing_a_file_also_rolls_back_its_bytes(self):
        self.minimal()
        before = self.snapshot()
        original = dictionary.write_atomic
        calls = 0

        def fail_after_write(path, data):
            nonlocal calls
            calls += 1
            original(path, data)
            if calls == 2:
                raise OSError('Synthetic post-replacement failure')

        with patch.object(dictionary, 'write_atomic', side_effect=fail_after_write):
            with self.assertRaisesRegex(OSError, 'post-replacement'):
                self.run_conversion()
        self.assertEqual(before, self.snapshot())


if __name__ == '__main__':
    unittest.main()
