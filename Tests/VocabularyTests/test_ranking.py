"""Offline calibration and attribution checks; no retired word/frequency sources required."""
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
        self.assertEqual((ROOT / 'mac/SI/Core/RankingCalibration.swift').read_text(), RANKING.calibration())
        self.assertEqual((ROOT / 'mac/SI/Resources/RankingNotices.txt').read_text(), RANKING.notices())

    def test_complete_frequency_attribution_is_retained_without_source_wordlists(self):
        notices = (ROOT / 'mac/SI/Resources/RankingNotices.txt').read_text()
        for text in ['Robyn Speer', 'creativecommons.org/licenses/by-sa/4.0/', 'SUBTLEX', 'Brysbaert', 'Google Books', 'OpenSubtitles']:
            self.assertIn(text, notices)

    def test_phonetic_regressions_are_explicit_unique_and_separate_from_historical_cases(self):
        rows = json.loads((ROOT / 'Data/Ranking/phonetic-regressions.json').read_text())
        previous = json.loads((ROOT / 'Data/Ranking/evaluation.json').read_text())
        previous += json.loads((ROOT / 'Data/Ranking/holdout.json').read_text())
        inputs = [row['input'] for row in rows]
        self.assertEqual(len(inputs), len(set(inputs)))
        self.assertTrue(set(inputs).isdisjoint(row['input'] for row in previous))
        for row in rows:
            self.assertEqual(row['category'], 'phonetic-regression')
            self.assertTrue(row['expected'])
            self.assertTrue(0 < len(row['input']) <= 64)

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
