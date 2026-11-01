"""Check the maintained lexical-only experiment without training its model."""

import tempfile
import unittest
from pathlib import Path

from llm.pinyin_to_text.csv_data.prepare import prepare, read_collection
from llm.pinyin_to_text.common import load_config, read_jsonl
from llm.pinyin_to_text.runtime import load_bundle
from llm.pinyin_to_text.tests.helpers import ROOT


class FocusedDataTests(unittest.TestCase):
    def test_focused_sources_are_chinese_characters_and_words_with_homophones(self):
        rows, sources, *_ = read_collection(ROOT / "data/pinyin-csv")
        self.assertEqual({source["group"] for source in sources}, {"characters", "words"})
        self.assertEqual(len(sources), 6)
        for split, records in rows.items():
            for row in records:
                with self.subTest(split=split, spelling=row["input"]):
                    self.assertEqual(row["language"], "zh")
                    self.assertRegex(row["input"], r"^[a-z]+$")
                    self.assertTrue(all("\u4e00" <= c <= "\u9fff" for c in row["target"]))
                    if row["groups"] == ["characters"]:
                        self.assertEqual(len(row["target"]), 1)
                    else:
                        self.assertEqual(row["groups"], ["words"])
                        self.assertIn(len(row["target"]), (2, 3))
        training = {(row["input"], row["target"]) for row in rows["train"]}
        self.assertIn(("ni", "你"), training)
        self.assertIn(("hao", "好"), training)
        self.assertIn(("nihao", "你好"), training)
        self.assertNotIn(("womenzaijia", "我们在家"), training)
        self.assertGreater(len({target for spelling, target in training if spelling == "shi"}), 1)

    def test_full_focused_collection_fits_the_small_model_without_truncation(self):
        config_path = ROOT / "configs/small-pinyin.json"
        config = load_config(config_path)
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "prepared"
            manifest = prepare(config_path, ROOT / "data/pinyin-csv", output)
            _, tokenizer, rows = load_bundle(output, config, ("train", "validation", "test"))
            self.assertEqual(len(manifest["sources"]), 6)
            for row in rows["train"]:
                self.assertTrue(all(character in tokenizer.lookup for character in row["target"]))
            for split, records in rows.items():
                self.assertEqual(list(read_jsonl(output / f"{split}.jsonl")), records)
                for row in records:
                    self.assertLessEqual(len(tokenizer.encode(row["input"])), config["model"]["max_source_tokens"])
                    self.assertLessEqual(len(tokenizer.encode(row["target"])), config["model"]["max_target_tokens"])
                    self.assertEqual(tokenizer.decode(tokenizer.encode(row["target"])), row["target"])
