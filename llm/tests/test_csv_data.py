import contextlib
import csv
import io
import tempfile
import unittest
from pathlib import Path

from llm.common import file_hash, read_json, read_jsonl, write_json
from llm.csv_data.prepare import csv_records, prepare, read_collection
from llm.evaluate import evaluate
from llm.runtime import load_bundle
from llm.tests.helpers import tiny_config
from llm.train import train


def collection(directory):
    root = Path(directory) / "csv"
    for split in ("train", "validation", "test"):
        (root / split).mkdir(parents=True)
    write_json(root / "provenance.json", {"schema_version": 1, "default": {
        "license": "GPL-3.0-only", "origin": "SI-authored synthetic CSV regression", "revision": "1"}, "files": {}})
    write_csv(root / "train/city.csv", [("beijing", "北京"), ("shanghai", "上海")])
    write_csv(root / "validation/city.csv", [("hangzhou", "杭州")])
    write_csv(root / "test/city.csv", [("chengdu", "成都")])
    return root


def write_csv(path, rows, language=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as stream:
        writer = csv.writer(stream, lineterminator="\n")
        writer.writerow(["input", "target", "language"] if language else ["input", "target"])
        writer.writerows(rows)


class CSVDataTests(unittest.TestCase):
    def test_directories_choose_split_without_generation_and_names_choose_groups(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = collection(temporary)
            config = tiny_config(temporary)  # Legacy noise=2 settings must not generate CSV rows.
            output = Path(temporary) / "prepared"
            manifest = prepare(config, root, output)
            self.assertEqual(manifest["counts"], {"train": {"zh": 2}, "validation": {"zh": 1}, "test": {"zh": 1}})
            self.assertEqual(manifest["data_config"]["augmentation"], "none")
            rows = list(read_jsonl(output / "train.jsonl"))
            self.assertEqual({r["input"] for r in rows}, {"beijing", "shanghai"})
            self.assertEqual(rows[0]["groups"], ["city"])
            self.assertNotIn("clean_input", rows[0])
            self.assertEqual(list(read_jsonl(output / "test.jsonl"))[0]["input"], "chengdu")
            _, tokenizer, _ = load_bundle(output, read_json(config), ("train", "validation"))
            self.assertNotIn("成", tokenizer.lookup)
            self.assertEqual(tokenizer.decode(tokenizer.encode("成都")), "成都")

    def test_many_nested_sources_discovered_with_no_registration_edits(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = collection(temporary)
            write_csv(root / "train/business/company.CSV", [("gongsi", "公司")])
            write_csv(root / "train/new group.csv", [("pengyou", "朋友")])
            rows, sources, _, _, _ = read_collection(root)
            self.assertEqual(len(rows["train"]), 4)
            self.assertIn("train/business/company", {s["id"] for s in sources})
            self.assertIn("business/company", {g for row in rows["train"] for g in row["groups"]})

    def test_csv_quotes_bom_optional_language_and_exact_bytes(self):
        data = '\ufeffinput,target,language\r\n"Hello,World42","Hello,World42",en\r\n"nihao,world","你好,world",mixed\r\n'.encode()
        rows = list(csv_records(data, "train/english.csv"))
        self.assertEqual(rows[0][:3], ("Hello,World42", "Hello,World42", "en"))
        self.assertEqual(rows[1][:3], ("nihao,world", "你好,world", "mixed"))
        self.assertEqual(next(csv_records(b'input,target\nx,y\n', "train/word.csv"))[2], "zh")

    def test_explicit_typos_are_retained_once(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = collection(temporary)
            write_csv(root / "train/chat.csv", [("nihao", "你好"), ("nihaoo", "你好")])
            rows, _, _, _, _ = read_collection(root)
            matches = [r for r in rows["train"] if r["target"] == "你好"]
            self.assertEqual({r["input"] for r in matches}, {"nihao", "nihaoo"})

    def test_same_split_duplicates_preserve_source_membership(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = collection(temporary)
            write_csv(root / "train/company.csv", [("beijing", "北京"), ("beijing", "北京")])
            rows, _, _, _, _ = read_collection(root)
            self.assertEqual(len(rows["train"]), 2)
            row = next(r for r in rows["train"] if r["input"] == "beijing")
            self.assertEqual(row["groups"], ["city", "company"])

    def test_input_and_target_cross_split_overlap_are_rejected_without_silent_moves(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = collection(temporary)
            write_csv(root / "test/conflict.csv", [("BEIJING", "别的城市")])
            with self.assertRaisesRegex(ValueError, "Cross-split input overlap"):
                read_collection(root)
            write_csv(root / "test/conflict.csv", [("beijng", "北京")])
            with self.assertRaisesRegex(ValueError, "Cross-split target overlap"):
                read_collection(root)

    def test_strict_headers_fields_utf8_and_control_validation(self):
        invalid = [b'pinyin,text\na,b\n', b'input,input,target\na,b,c\n', b'input,target\na,b,c\n',
                   b'input,target\na\n', b'input,target\na,\n', b'input,target,language\na,b,fr\n',
                   b'input,target\na,"b\nc"\n', b'input,target\n\xff,x\n',
                   ('input,target\na,' + '字' * 2000 + '\n').encode()]
        for data in invalid:
            with self.subTest(data=data[:30]), self.assertRaises(ValueError):
                list(csv_records(data, "train/bad.csv"))

    def test_snapshots_reproducibility_and_later_edits_do_not_change_old_bundle(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = collection(temporary)
            config = tiny_config(temporary)
            a, b, c = (Path(temporary) / name for name in ("a", "b", "c"))
            first = prepare(config, root, a)
            self.assertEqual(first, prepare(config, root, b))
            original = file_hash(a / "source_csv/train/city.csv")
            write_csv(root / "train/city.csv", [("beijing", "北京"), ("shanghai", "上海"), ("nanjing", "南京")])
            second = prepare(config, root, c)
            self.assertNotEqual(first["dataset_id"], second["dataset_id"])
            self.assertEqual(file_hash(a / "source_csv/train/city.csv"), original)
            self.assertEqual(len(list(read_jsonl(a / "train.jsonl"))), 2)
            with self.assertRaisesRegex(ValueError, "already exists"):
                prepare(config, root, a)

    def test_bad_data_never_publishes_partial_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = collection(temporary)
            write_csv(root / "train/bad.csv", [("a", "字" * 100)])
            output = Path(temporary) / "bad"
            with self.assertRaisesRegex(ValueError, "max_target_tokens"):
                prepare(tiny_config(temporary), root, output)
            self.assertFalse(output.exists())

    def test_missing_split_unknown_split_and_provenance_are_actionable_errors(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = collection(temporary)
            (root / "validation/city.csv").unlink()
            with self.assertRaisesRegex(ValueError, "validation/"):
                read_collection(root)
            (root / "validation").rmdir()
            with self.assertRaisesRegex(ValueError, "Missing validation"):
                read_collection(root)
            (root / "validation").mkdir()
            (root / "val").mkdir()
            with self.assertRaisesRegex(ValueError, "Unexpected split"):
                read_collection(root)

    def test_source_license_overrides_are_retained(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = collection(temporary)
            value = read_json(root / "provenance.json")
            value["files"]["train/city.csv"] = {"license": "MIT", "origin": "https://example.invalid/reviewed-source", "revision": "pinned"}
            write_json(root / "provenance.json", value)
            _, sources, _, _, _ = read_collection(root)
            self.assertEqual(next(s for s in sources if s["id"] == "train/city")["license"], "MIT")
            self.assertEqual(next(s for s in sources if s["id"] == "test/city")["license"], "GPL-3.0-only")

    def test_static_csv_bundle_trains_resumes_and_evaluates(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = collection(temporary)
            config = tiny_config(temporary)
            data, run, report = (Path(temporary) / name for name in ("data", "run", "report.json"))
            manifest = prepare(config, root, data)
            with contextlib.redirect_stdout(io.StringIO()):
                train(config, data, run, "cpu", max_steps=1, threads=2)
                result = train(config, data, run, "cpu", resume=True, max_steps=2, threads=2)
            self.assertEqual(result["step"], 2)
            metrics = evaluate(data, "test", report, run / "best.pt", device_name="cpu", limit=1, threads=2)
            self.assertEqual(metrics["dataset_id"], manifest["dataset_id"])
            self.assertEqual(metrics["evaluated_cases"], 1)
