import contextlib
import io
import tempfile
import unittest
from pathlib import Path

import torch

from llm.common import read_json, read_jsonl, write_json
from llm.compare import compare
from llm.evaluate import evaluate
from llm.export import export
from llm.csv_data.prepare import prepare
from llm.runtime import load_checkpoint
from llm.tests.helpers import collection, tiny_config, write_csv
from llm.train import train


class WorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory()
        cls.path = Path(cls.temporary.name)
        cls.config = tiny_config(cls.path, batch_size=64, gradient_accumulation=2, activation_checkpointing=True)
        config = read_json(cls.config)
        config["model"]["dropout"] = .2
        write_json(cls.config, config)
        cls.data = cls.path / "data"
        prepare(cls.config, collection(cls.path), cls.data)
        with contextlib.redirect_stdout(io.StringIO()):
            train(cls.config, cls.data, cls.path / "full", "cpu", max_steps=4, threads=2)
            train(cls.config, cls.data, cls.path / "resumed", "cpu", max_steps=2, threads=2)
            train(cls.config, cls.data, cls.path / "resumed", "cpu", resume=True, max_steps=4, threads=2)
        cls.full = torch.load(cls.path / "full/last.pt", weights_only=True)
        cls.resumed = torch.load(cls.path / "resumed/last.pt", weights_only=True)

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def test_resume_matches_uninterrupted_training_with_dropout_and_epoch_rollover(self):
        self.assertEqual(self.full["step"], 4)
        self.assertGreater(self.full["epoch"], 0)
        self.assertEqual((self.full["epoch"], self.full["cursor"]), (self.resumed["epoch"], self.resumed["cursor"]))
        for key, tensor in self.full["model"].items():
            self.assertTrue(torch.equal(tensor, self.resumed["model"][key]), key)
        self.assertTrue(torch.equal(self.full["torch_rng"], self.resumed["torch_rng"]))

    def test_train_never_reads_test_and_rejects_changed_training_data(self):
        test_file = self.data / "test.jsonl"
        original = test_file.read_bytes()
        try:
            test_file.write_text("not json", encoding="utf-8")
            with contextlib.redirect_stdout(io.StringIO()):
                train(self.config, self.data, self.path / "without-test", "cpu", max_steps=1, threads=2)
            with self.assertRaisesRegex(ValueError, "modified"):
                evaluate(self.data, "test", self.path / "bad.json", config_path=self.config, baseline="literal", device_name="cpu")
        finally:
            test_file.write_bytes(original)
        train_file = self.data / "train.jsonl"
        original = train_file.read_bytes()
        try:
            train_file.write_bytes(original + b"\n")
            with self.assertRaisesRegex(ValueError, "modified"):
                train(self.config, self.data, self.path / "tampered", "cpu", max_steps=1, threads=2)
        finally:
            train_file.write_bytes(original)

    def test_different_config_cannot_resume_and_existing_runs_are_preserved(self):
        changed = read_json(self.config)
        changed["training"]["learning_rate"] *= 2
        other = self.path / "other.json"
        write_json(other, changed)
        with self.assertRaisesRegex(ValueError, "Resume requires"):
            train(other, self.data, self.path / "resumed", "cpu", resume=True, max_steps=5)
        with self.assertRaisesRegex(ValueError, "already exists"):
            train(self.config, self.data, self.path / "resumed", "cpu", max_steps=1)

    def test_validation_test_reports_and_comparison(self):
        a, b, c = (self.path / name for name in ("evaluation-a.json", "evaluation-b.json", "evaluation-c.json"))
        evaluate(self.data, "test", a, self.path / "full/best.pt", device_name="cpu", limit=2, threads=2)
        evaluate(self.data, "test", b, config_path=self.config, baseline="literal", device_name="cpu", limit=2, threads=2)
        report = read_json(a)
        self.assertTrue(report["partial"])
        self.assertEqual(report["evaluated_cases"], 2)
        self.assertEqual(len(compare([a, b])), 2)
        evaluate(self.data, "validation", c, config_path=self.config, baseline="literal", device_name="cpu", limit=2, threads=2)
        with self.assertRaisesRegex(ValueError, "different"):
            compare([a, c])
        with self.assertRaisesRegex(ValueError, "already exists"):
            evaluate(self.data, "test", a, config_path=self.config, baseline="literal", device_name="cpu", limit=1)

    def test_exports_are_loadable_and_training_logs_contain_no_sample_text(self):
        path = self.path / "inference.pt"
        export(self.path / "full/best.pt", path)
        checkpoint, model, tokenizer = load_checkpoint(path, torch.device("cpu"))
        self.assertNotIn("optimizer", checkpoint)
        self.assertEqual(tokenizer.digest, checkpoint["tokenizer_digest"])
        self.assertEqual(model.config["vocab_size"], 512)
        text = (self.path / "full/metrics.jsonl").read_text(encoding="utf-8")
        self.assertNotIn("nihao", text)
        self.assertNotIn("你好", text)

    def test_external_frozen_benchmarks_and_leakage_detection(self):
        with tempfile.TemporaryDirectory() as directory:
            benchmark = collection(Path(directory) / "benchmark")
            write_csv(benchmark / "test/city.csv", [("neverSeenBenchmark42", "neverSeenBenchmark42", "en")], language=True)
            a, b = Path(directory) / "a.json", Path(directory) / "b.json"
            evaluate(self.data, "test", a, self.path / "full/best.pt", device_name="cpu", threads=2, benchmark_path=benchmark)
            evaluate(self.data, "test", b, config_path=self.config, baseline="literal", device_name="cpu", threads=2, benchmark_path=benchmark)
            self.assertEqual(len(compare([a, b])), 2)
            self.assertEqual(read_json(b)["metrics"]["overall"]["top1_accuracy"], 1)
            alternate = Path(directory) / "alternate"
            alternate.mkdir()
            sources = collection(alternate)
            write_csv(sources / "train/english.csv", [("additionalTrainingPair", "additionalTrainingPair", "en")], language=True)
            prepare(self.config, sources, alternate / "data")
            c = Path(directory) / "c.json"
            evaluate(alternate / "data", "test", c, config_path=self.config, baseline="literal", device_name="cpu",
                     threads=2, benchmark_path=benchmark)
            self.assertNotEqual(read_json(b)["training_dataset_id"], read_json(c)["training_dataset_id"])
            self.assertEqual(len(compare([b, c])), 2)
            used = next(read_jsonl(self.data / "train.jsonl"))
            write_csv(benchmark / "test/city.csv", [(used["input"], used["target"], used["language"])], language=True)
            with self.assertRaisesRegex(ValueError, "overlaps"):
                evaluate(self.data, "test", Path(directory) / "leaked.json", config_path=self.config,
                         baseline="literal", device_name="cpu", threads=2, benchmark_path=benchmark)

    def test_older_model_config_remains_loadable_for_inference_without_sources(self):
        payload = dict(self.full)
        payload["config"] = {**payload["config"], "data": {"split_ratios": [.9, .05, .05], "noise_variants": 2, "max_edits": 1}}
        path = self.path / "previous-format.pt"
        torch.save(payload, path)
        checkpoint, model, tokenizer = load_checkpoint(path, torch.device("cpu"))
        self.assertEqual(model.config["vocab_size"], 512)
        self.assertEqual(tokenizer.digest, checkpoint["tokenizer_digest"])
