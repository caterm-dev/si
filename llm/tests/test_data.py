import tempfile
import unittest
from pathlib import Path

from llm.common import file_hash, load_config, read_json, read_jsonl, write_json
from llm.noise import variants
from llm.prepare import clean_rows, normalized, prepare, split_rows, text_input
from llm.sources import load_sources
from llm.tests.helpers import ROOT, manifest_for, tiny_config
from llm.tokenizer import Tokenizer


class DataTests(unittest.TestCase):
    def test_lossless_unknown_unicode_and_exact_case(self):
        tokenizer = Tokenizer.fit([{"input": "nihao", "target": "你好"}], 264)
        for text in ("你好", "HelloWorld42", "女lüu:", "\U00020000🙂e\u0301", "", "a'b"):
            self.assertEqual(tokenizer.decode(tokenizer.encode(text)), text)

    def test_tokenizer_fits_only_training_characters(self):
        tokenizer = Tokenizer.fit([{"input": "wo", "target": "我"}], 512)
        self.assertNotIn("家", tokenizer.lookup)
        self.assertEqual(tokenizer.decode(tokenizer.encode("家")), "家")

    def test_invalid_utf8_is_rejected(self):
        with self.assertRaises(UnicodeDecodeError):
            Tokenizer(512, []).decode([4 + 0xFF])

    def test_noise_is_repeatable_bounded_and_preserves_label(self):
        row = {"input": "womenzaijia", "target": "我们在家", "language": "zh"}
        first = list(variants(row, 42, 4, 1))
        self.assertEqual(first, list(variants(row, 42, 4, 1)))
        self.assertEqual(len(first), 4)
        self.assertEqual({v["noise"] for v in first}, {"delete", "insert", "substitute", "transpose"})
        self.assertTrue(all(v["target"] == row["target"] and v["input"] != row["input"] for v in first))
        self.assertEqual(list(variants(row, 42, 0, 1)), [])

    def test_preparation_is_reproducible_and_disjoint_after_noise(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary)
            a = prepare(ROOT / "configs/smoke.json", ROOT / "configs/sources.json", path / "a")
            b = prepare(ROOT / "configs/smoke.json", ROOT / "configs/sources.json", path / "b")
            self.assertEqual(a, b)
            splits = {split: list(read_jsonl(path / "a" / f"{split}.jsonl")) for split in ("train", "validation", "test")}
            for field in ("input", "target", "group"):
                sets = [{normalized(r[field]) for r in records} for records in splits.values()]
                self.assertFalse(sets[0] & sets[1] or sets[0] & sets[2] or sets[1] & sets[2])
            tokenizer = Tokenizer.load(path / "a/tokenizer.json")
            training_chars = set("".join(r["input"] + r["target"] for r in splits["train"]))
            self.assertTrue(set(tokenizer.characters) <= training_chars)
            with self.assertRaisesRegex(ValueError, "already exists"):
                prepare(ROOT / "configs/smoke.json", ROOT / "configs/sources.json", path / "a")

    def test_ambiguous_input_and_document_groups_stay_together(self):
        with tempfile.TemporaryDirectory() as temporary:
            records = [{"input": f"reading{i}", "target": f"输出{i}", "language": "zh"} for i in range(80)]
            records += [{"input": "women", "target": "我们", "language": "zh", "group_id": "document"},
                        {"input": "women", "target": "women", "language": "en"},
                        {"input": "different", "target": "另一句", "language": "zh", "group_id": "document"},
                        {"input": "WOMEN", "target": "妇女", "language": "zh"}]
            source = manifest_for(temporary, records)
            rows, memberships, _ = clean_rows(source)
            splits = split_rows(rows, memberships, 42, [.7, .15, .15])
            locations = [name for name, rows in splits.items() if any(r["input"] == "women" for r in rows)]
            self.assertEqual(len(locations), 1)
            related = [r for r in splits[locations[0]] if r["input"] in ("women", "different", "WOMEN")]
            self.assertEqual(len(related), 4)

    def test_missing_provenance_and_changed_sources_fail(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = manifest_for(temporary, [{"input": "a", "target": "a", "language": "en"}])
            manifest = read_json(source)
            del manifest["sources"][0]["license"]
            write_json(source, manifest)
            with self.assertRaisesRegex(ValueError, "license"):
                list(load_sources(source))
            source = manifest_for(temporary, [{"input": "a", "target": "a", "language": "en"}])
            Path(temporary, "pairs.jsonl").write_text("{}\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "checksum"):
                list(load_sources(source))

    def test_long_labels_fail_without_truncation_or_partial_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary)
            config = tiny_config(path)
            value = read_json(config)
            value["model"]["max_target_tokens"] = 3
            write_json(config, value)
            with self.assertRaisesRegex(ValueError, "max_target_tokens"):
                prepare(config, ROOT / "configs/sources.json", path / "bad")
            self.assertFalse((path / "bad").exists())

    def test_control_input_and_mixed_text_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = manifest_for(temporary, [{"input": "a\nb", "target": "a", "language": "en"}])
            with self.assertRaisesRegex(ValueError, "control"):
                clean_rows(source)
            source = manifest_for(temporary, [{"target": "你好hello", "language": "mixed"}], "text")
            with self.assertRaisesRegex(ValueError, "explicit"):
                clean_rows(source)

    def test_imported_real_errors_keep_their_labels(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = manifest_for(temporary, [{"input": "hlelo", "target": "hello", "language": "en",
                                                "noise": "transpose", "group_id": "original"}])
            rows, _, _ = clean_rows(source)
            self.assertEqual(rows[0]["noise"], "transpose")

    def test_text_adapters(self):
        self.assertEqual(text_input("Hello World", "en"), "Hello World")
        try:
            import pypinyin  # noqa: F401
        except ImportError:
            self.skipTest("Optional pypinyin is not installed")
        self.assertEqual(text_input("你好", "zh"), "nihao")
        self.assertEqual(text_input("我们在家", "zh"), "womenzaijia")
        self.assertEqual(text_input("女", "zh"), "nv")

    def test_invalid_config_fails_early(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = tiny_config(temporary)
            config = read_json(path)
            config["data"]["split_ratios"] = [1, 0, 0]
            write_json(path, config)
            with self.assertRaisesRegex(ValueError, "ratios"):
                load_config(path)
