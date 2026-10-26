import tempfile
import unittest
from pathlib import Path

from llm.build_corpus import DEFAULT_SEED, build
from llm.common import file_hash, read_jsonl
from llm.prepare import clean_rows, split_rows


class CorpusTests(unittest.TestCase):
    def test_starter_is_reproducible_short_and_has_expected_readings(self):
        with tempfile.TemporaryDirectory() as temporary:
            a, b = Path(temporary) / "a", Path(temporary) / "b"
            summary = build(DEFAULT_SEED, a)
            self.assertEqual(summary, build(DEFAULT_SEED, b))
            for name in ("pairs.jsonl", "sources.json", "summary.json", "NOTICE.md", "LICENSE"):
                self.assertEqual(file_hash(a / name), file_hash(b / name))
            self.assertGreaterEqual(summary["unique_words"], 1500)
            self.assertGreaterEqual(summary["unique_chat_outputs"], 4000)
            self.assertLessEqual(summary["maximum_output_characters"], 16)
            readings = {}
            for row in read_jsonl(a / "pairs.jsonl"):
                readings.setdefault(row["target"], set()).add(row["input"])
            for text, spelling in {"你好": "nihao", "我们在家": "womenzaijia", "银行": "yinhang",
                                   "音乐": "yinyue", "行业": "hangye", "重庆": "chongqing",
                                   "我得先去忙了": "wodeixianqumangle"}.items():
                self.assertIn(spelling, readings[text])
            self.assertEqual(readings["行"], {"hang", "xing"})
            self.assertEqual(readings["长"], {"chang", "zhang"})
            self.assertNotIn("要不要一起吃饭吧", readings)
            self.assertNotIn("我想做点苹果", readings)
            with self.assertRaisesRegex(ValueError, "already exists"):
                build(DEFAULT_SEED, a)

    def test_related_template_variants_stay_in_one_split(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "corpus"
            build(DEFAULT_SEED, path)
            rows, groups, _ = clean_rows(path / "sources.json")
            splits = split_rows(rows, groups, 42, [.9, .05, .05])
            locations = {r["target"]: split for split, records in splits.items() for r in records}
            self.assertEqual(locations["我在家"], locations["你明天在家"])
            self.assertEqual(locations["我在家"], locations["你现在在家吗"])
            self.assertEqual(locations["我想吃苹果"], locations["我们想买点苹果"])
