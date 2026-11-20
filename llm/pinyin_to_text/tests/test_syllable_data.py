"""Check the shipped syllable dataset without training the configured model."""

from collections import defaultdict
from pathlib import Path
import tempfile
import unittest

from llm.pinyin_to_text.common import file_hash, load_config, normalized, read_json
from llm.pinyin_to_text.csv_data.prepare import prepare
from llm.pinyin_to_text.runtime import MAX_SYLLABLE_PATHS, load_bundle
from llm.pinyin_to_text.tests.helpers import ROOT


class SyllableDataTests(unittest.TestCase):
    def test_default_collection_prepares_all_splits_with_explicit_syllables(self):
        source = ROOT / "data/syllable-csv"
        config_path = ROOT / "configs/contextual-pinyin.json"
        config = load_config(config_path)
        declared = read_json(source / "provenance.json")["materialization"]
        for name, digest in declared["csv_sha256"].items():
            self.assertEqual(file_hash(source / name), digest)

        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "prepared"
            manifest = prepare(config_path, source, output)
            self.assertEqual(manifest["counts"], {
                "train": {"zh": 96000}, "validation": {"zh": 2000}, "test": {"zh": 2000},
            })
            _, tokenizer, rows = load_bundle(output, config, ("train", "validation", "test"))
            paths = defaultdict(set)
            batch_values = {group: defaultdict(set) for group in ("examples", "additional")}
            for split, records in rows.items():
                self.assertEqual(sum(bool(row["context"]) for row in records), declared["counts"][split]["with_context"])
                self.assertTrue(all(row["syllables"].replace(" ", "") == row["input"] for row in records))
                self.assertTrue(all(len(row["syllables"].split()) == len(row["target"]) for row in records))
                for group in batch_values:
                    count = sum(row["groups"] == [group] for row in records)
                    self.assertEqual(count, 48000 if split == "train" else 1000)
                for row in records:
                    group, = row["groups"]
                    for field in ("input", "target"):
                        batch_values[group][field].add(normalized(row[field]))
                    paths[row["input"]].add(row["syllables"])
                    target = row["target"]
                    self.assertEqual(tokenizer.decode(tokenizer.encode(target)), target)
            for field in ("input", "target"):
                self.assertTrue(batch_values["examples"][field].isdisjoint(batch_values["additional"][field]))
            self.assertEqual(sum(row["with_context"] for row in declared["counts"].values()), 10000)
            self.assertGreater(max(map(len, paths.values())), 1)
            self.assertLessEqual(max(map(len, paths.values())), MAX_SYLLABLE_PATHS)
