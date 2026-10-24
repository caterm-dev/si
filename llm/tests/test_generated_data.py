from collections import defaultdict
import json
from pathlib import Path
import re
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from generate_data import TOTALS, VERSION, authored_words, expand, frames, generate
from prepare import build
from protocol import ROOT, Request, compact, identity, read_jsonl


def one_typing_error(source, observed):
    """Independent check for one insertion, deletion, substitution or adjacent swap."""
    if source == observed:
        return False
    if abs(len(source) - len(observed)) == 1:
        shorter, longer = sorted((source, observed), key=len)
        index = next((i for i, pair in enumerate(zip(shorter, longer)) if pair[0] != pair[1]), len(shorter))
        return shorter[index:] == longer[index + 1:]
    if len(source) != len(observed):
        return False
    changed = [i for i, pair in enumerate(zip(source, observed)) if pair[0] != pair[1]]
    return len(changed) == 1 or (
        len(changed) == 2 and changed[1] == changed[0] + 1
        and source[changed[0]] == observed[changed[1]]
        and source[changed[1]] == observed[changed[0]]
    )


class GeneratedDataTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.seeds = read_jsonl(ROOT / "data/seeds.jsonl")
        cls.partitions = build(ROOT / "data/seeds.jsonl")
        cls.canonical = dict(authored_words())
        for spec in frames():
            for text, syllables in expand(spec):
                cls.canonical[text] = syllables

    def test_ten_thousand_distinct_requests_with_exact_partition_sizes(self):
        self.assertEqual(len(self.seeds), 10000)
        self.assertEqual({split: len(rows) for split, rows in self.partitions.items()}, TOTALS)
        requests = [compact(Request.from_dict(seed["request"]).as_dict()) for seed in self.seeds]
        self.assertEqual(len(set(requests)), len(requests))
        self.assertEqual(len({seed["id"] for seed in self.seeds}), len(self.seeds))

    def test_families_and_complete_conversion_targets_do_not_cross_splits(self):
        families, targets = defaultdict(set), defaultdict(set)
        for split, rows in self.partitions.items():
            for row in rows:
                families[row["group"]].add(split)
                if row["request"]["task"] == "convert":
                    for candidate in row["expected"]:
                        targets[identity(candidate)].add(split)
        self.assertTrue(all(len(splits) == 1 for splits in families.values()))
        self.assertTrue(all(len(splits) == 1 for splits in targets.values()))

    def test_original_examples_survive_and_partial_world_leak_is_repaired(self):
        current = {compact(Request.from_dict(seed["request"]).as_dict()): seed for seed in self.seeds}
        for seed in read_jsonl(ROOT / "data/bootstrap.jsonl"):
            for spelling in [seed["request"]["input"], *seed["variants"]]:
                request = Request.from_dict({**seed["request"], "input": spelling})
                actual = current[compact(request.as_dict())]
                self.assertEqual(actual["candidates"], seed["candidates"])
                self.assertEqual(actual["split"], "valid" if seed["id"] == "partial-world" else seed["split"])
        repaired = next(seed for seed in self.seeds if seed["id"] == "partial-world")
        world = next(seed for seed in self.seeds if seed["id"] == "ambiguous-shijie")
        self.assertEqual((repaired["split"], repaired["group"]), (world["split"], world["group"]))

    def test_generated_typo_targets_are_exactly_one_error_from_authored_readings(self):
        checked = 0
        for seed in self.seeds:
            if seed["id"].startswith(VERSION) and seed["category"] == "typo":
                for candidate in seed["candidates"]:
                    canonical = "".join(self.canonical[candidate["text"]])
                    self.assertTrue(one_typing_error(canonical, seed["request"]["input"]), seed["id"])
                checked += 1
        self.assertGreater(checked, 1500)

    def test_partial_and_initial_labels_match_authored_spelling(self):
        counts = defaultdict(int)
        for seed in self.seeds:
            category = seed["category"]
            if not seed["id"].startswith(VERSION) or category not in ("partial", "initials"):
                continue
            for candidate in seed["candidates"]:
                syllables = self.canonical[candidate["text"]]
                source = seed["request"]["input"]
                if category == "partial":
                    canonical = "".join(syllables)
                    self.assertTrue(canonical.startswith(source))
                    self.assertIn(len(canonical) - len(source), (1, 2))
                else:
                    self.assertEqual(source, "".join(syllable[0] for syllable in syllables))
            counts[category] += 1
        self.assertGreater(counts["partial"], 800)
        self.assertGreater(counts["initials"], 300)

    def test_mixed_labels_keep_english_bytes_and_preservation_does_not_execute_text(self):
        for seed in self.seeds:
            if not seed["id"].startswith(VERSION):
                continue
            if seed["category"] == "mixed":
                for candidate in seed["candidates"]:
                    for token in re.findall(r"[A-Za-z][A-Za-z0-9-]*", candidate["text"]):
                        self.assertIn(token, seed["request"]["input"])
            elif seed["category"] == "preserve":
                self.assertEqual([row["text"] for row in seed["candidates"]], [seed["request"]["input"]])

    def test_prediction_labels_contain_suffixes_without_context_echo(self):
        checked = 0
        for seed in self.seeds:
            request = Request.from_dict(seed["request"])
            if request.task == "predict":
                self.assertTrue(request.context)
                for candidate in seed["candidates"]:
                    self.assertFalse(candidate["text"].startswith(request.context + request.input))
                checked += 1
        self.assertGreater(checked, 500)

    def test_generated_snapshot_is_reproducible(self):
        content, _ = generate()
        self.assertEqual(content, (ROOT / "data/seeds.jsonl").read_text())


if __name__ == "__main__":
    unittest.main()
