"""Offline model provenance and serializer validation; no third-party Python packages."""
import gzip
import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('si_ranking', ROOT / 'scripts/ranking.py')
RANKING = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RANKING)


class RankingDataTests(unittest.TestCase):
    def test_checked_in_native_model_matches_pinned_source(self):
        self.assertEqual(RANKING.OUTPUT.read_text(), RANKING.build())
        self.assertEqual((ROOT / 'mac/SI/Core/RankingCalibration.swift').read_text(), RANKING.calibration())
        self.assertEqual((ROOT / 'mac/SI/Resources/RankingNotices.txt').read_text(), RANKING.notices())

    def test_rejects_unsupported_truncated_and_invalid_envelopes(self):
        for data in [b'', b'\x91', b'\x91\xc0', b'\x91\x80', b'\x91\xa9truncated']:
            with self.subTest(data=data), self.assertRaises(ValueError):
                RANKING.unpack(data)

    def test_known_source_frequencies_and_complete_attribution_are_retained(self):
        buckets = RANKING.unpack(gzip.decompress((RANKING.SOURCE / 'large_en.msgpack.gz').read_bytes()))
        bins = {word: index for index, bucket in enumerate(buckets) for word in bucket}
        self.assertLess(bins['ability'], bins['abilities'])
        self.assertLess(bins['the'], bins['ability'])
        notices = (ROOT / 'mac/SI/Resources/RankingNotices.txt').read_text()
        for text in ['Robyn Speer', 'creativecommons.org/licenses/by-sa/4.0/', 'SUBTLEX', 'Brysbaert', 'Google Books', 'OpenSubtitles']:
            self.assertIn(text, notices)

    def test_calibration_and_quality_partitions_are_disjoint(self):
        calibration = json.loads((ROOT / 'Data/Ranking/calibration.json').read_text())['examples']
        development = json.loads((ROOT / 'Data/Ranking/evaluation.json').read_text())
        holdout = json.loads((ROOT / 'Data/Ranking/holdout.json').read_text())
        normalize = lambda s: s.replace(' ', '').lower()
        calibration_outputs = {normalize(''.join(row['tokens'])) for row in calibration}
        self.assertTrue(calibration_outputs.isdisjoint(normalize(row['expected']) for row in development + holdout))
        self.assertTrue({row['input'] for row in development}.isdisjoint(row['input'] for row in holdout))
        self.assertEqual(len({row['input'] for row in development + holdout}), len(development + holdout))


if __name__ == '__main__':
    unittest.main()
