"""Reviewed public-corpus data integrity; no downloads, private data or model needed."""

from collections import defaultdict
import csv
import hashlib
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
DATA = ROOT / 'Data/Vocabulary'
SOURCES = ('lccc', 'mc4', 'kubernetes', 'tensorflow', 'mdn', 'wikipedia')


def rows(path):
    with path.open(encoding='utf-8', newline='') as handle:
        return list(csv.DictReader(handle))


class CorpusVocabularyTests(unittest.TestCase):
    def test_reviewed_additions_have_evidence_valid_readings_and_no_preexisting_outputs(self):
        catalog = rows(DATA / 'chinese/corpus.csv')
        evidence = rows(DATA / 'Corpus/accepted.csv')
        decisions = json.loads((DATA / 'Corpus/decisions.json').read_text())
        snapshot = json.loads((DATA / 'Corpus/snapshot.json').read_text())
        self.assertEqual(len(catalog), 266)
        self.assertEqual(len({r['text'] for r in catalog}), len(catalog))
        self.assertEqual({r['text']: r['reading'] for r in catalog}, decisions['accepted'])
        self.assertEqual({tuple(r[k] for k in ('text', 'reading', 'weight')) for r in catalog},
                         {tuple(r[k] for k in ('text', 'reading', 'weight')) for r in evidence})
        rejected = [word for words in decisions['rejected_groups'].values() for word in words]
        self.assertEqual(len(set(rejected)), 197)
        self.assertTrue(set(rejected).isdisjoint(decisions['accepted']))
        self.assertEqual(len(rejected) + len(catalog), snapshot['decisions']['eligible'])
        for name, checksum in snapshot['files'].items():
            self.assertEqual(hashlib.sha256((ROOT / name).read_bytes()).hexdigest(), checksum, name)
        characters = defaultdict(set)
        new = {r['text'] for r in catalog}
        for path in (DATA / 'chinese').glob('*.csv'):
            if path.name == 'corpus.csv':
                continue
            with path.open(encoding='utf-8', newline='') as handle:
                for row in csv.DictReader(handle):
                    self.assertNotIn(row['text'], new)
                    if len(row['text']) == 1 and "'" not in row['reading']:
                        characters[row['text']].add(row['reading'])
        for row in evidence:
            text, reading = row['text'], row['reading'].split("'")
            self.assertTrue(2 <= len(text) <= 7)
            self.assertEqual(len(text), len(reading))
            for character, syllable in zip(text, reading, strict=True):
                self.assertIn(syllable, characters[character], text)
            count, fragments = int(row['count']), int(row['line_count'])
            self.assertGreaterEqual(count, 20)
            self.assertGreaterEqual(fragments, 10)
            self.assertGreaterEqual(count, fragments)
            self.assertEqual(count, sum(int(row[n]) for n in SOURCES))
            self.assertTrue(int(row['supported_sources']) >= 2 or fragments >= 100)
            self.assertTrue(10 <= int(row['weight']) <= 5000)

    def test_only_eight_bounded_corrections_match_authoritative_base_and_evidence(self):
        corrections = rows(DATA / 'Corpus/corrections.csv')
        self.assertEqual(len(corrections), 8)
        targets = {r['text']: r for r in corrections}
        references = {r['reference_text']: r for r in corrections}
        found = set()
        with (DATA / 'chinese/base.csv').open(encoding='utf-8', newline='') as handle:
            for row in csv.DictReader(handle):
                if row['text'] in targets and row['reading'] == targets[row['text']]['reading']:
                    self.assertEqual(row['weight'], targets[row['text']]['new_weight'])
                    found.add(row['text'])
                if row['text'] in references and row['reading'] == references[row['text']]['reading']:
                    self.assertEqual(row['weight'], references[row['text']]['reference_weight'])
        self.assertEqual(found, set(targets))
        for row in corrections:
            old, new, rival = (int(row[k]) for k in ('old_weight', 'new_weight', 'reference_weight'))
            self.assertLess(old, new)
            self.assertLessEqual(new, 2 * old)
            self.assertEqual(new, (rival * 105 + 99) // 100)
            self.assertGreaterEqual(int(row['hanlp_count']), 4 * max(1, int(row['reference_surface_count'])))
            supported = {n for n in SOURCES if int(row[n]) >= 10
                         and int(row[n]) >= 2 * max(1, int(row['reference_' + n]))}
            self.assertGreaterEqual(len(supported), 3)
            self.assertTrue({'lccc', 'mc4'}.issubset(supported))
            self.assertEqual(row['source_file'], 'chinese/base.csv')


if __name__ == '__main__':
    unittest.main()
