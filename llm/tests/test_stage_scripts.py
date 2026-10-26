"""Verify preset entry points independently with tiny synthetic CPU fixtures."""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from llm.common import file_hash, read_json
from llm.tests.helpers import ROOT, collection, tiny_config


class StageScriptTests(unittest.TestCase):
    def environment(self, **overrides):
        environment = {key: value for key, value in os.environ.items() if not key.startswith("SI_LLM_")}
        environment["SI_LLM_PYTHON"] = sys.executable
        environment.update(overrides)
        return environment

    def execute(self, script, directory, environment, *args):
        return subprocess.run([str(ROOT / "scripts" / script), *args], cwd=directory,
                              env=environment, text=True, capture_output=True, timeout=90)

    def test_presets_dispatch_only_the_requested_module_without_training(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            recorder = root / "record-python"
            recorder.write_text(f"#!{sys.executable}\nimport json, sys\nprint(json.dumps(sys.argv[1:]))\n")
            recorder.chmod(0o755)
            env = self.environment(SI_LLM_PYTHON=str(recorder))
            modules = {"data.sh": "llm.csv_data.prepare", "run.sh": "llm.train",
                       "validation.sh": "llm.evaluate", "test.sh": "llm.test",
                       "infer.sh": "llm.predict", "export.sh": "llm.export", "resume.sh": "llm.train"}
            for script, module in modules.items():
                with self.subTest(script=script):
                    result = self.execute(script, root, env)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    args = json.loads(result.stdout)
                    self.assertEqual(args[:2], ["-m", module])
                    if script in ("run.sh", "resume.sh", "validation.sh", "test.sh", "infer.sh"):
                        self.assertEqual(args[args.index("--device") + 1], "mps")
                    self.assertTrue(any("static-csv-v2" in arg for arg in args))
            self.assertEqual(list(root.iterdir()), [recorder])

    def test_no_argument_stages_keep_preparation_training_and_reports_separate(self):
        with tempfile.TemporaryDirectory(prefix="si stages ") as temporary:
            root = Path(temporary)
            data, run, reports = root / "data", root / "run", root / "reports"
            env = self.environment(SI_LLM_CONFIG=str(tiny_config(root, max_steps=1)),
                                   SI_LLM_CSV_ROOT=str(collection(root)), SI_LLM_DATA=str(data),
                                   SI_LLM_RUN=str(run), SI_LLM_REPORT_ROOT=str(reports),
                                   SI_LLM_DEVICE="cpu", SI_LLM_THREADS="2")

            def execute(script, *args):
                result = self.execute(script, root, env, *args)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                return result

            execute("data.sh")
            self.assertTrue((data / "manifest.json").is_file())
            self.assertFalse(run.exists())
            self.assertFalse(reports.exists())
            execute("run.sh")
            self.assertTrue((run / "best.pt").is_file())
            self.assertFalse(reports.exists())
            self.assertFalse((run / "inference.pt").exists())
            execute("validation.sh")
            self.assertEqual(read_json(reports / "validation.json")["split"], "validation")
            self.assertFalse(read_json(reports / "validation.json")["partial"])
            self.assertFalse((reports / "test.json").exists())
            execute("test.sh")
            self.assertEqual(read_json(reports / "test.json")["split"], "test")
            self.assertFalse(read_json(reports / "test.json")["partial"])
            execute("infer.sh", "--input", "womenzaijia")
            execute("export.sh")
            self.assertTrue((run / "inference.pt").is_file())
            digest = file_hash(run / "best.pt")
            self.assertNotEqual(self.execute("data.sh", root, env).returncode, 0)
            self.assertNotEqual(self.execute("run.sh", root, env).returncode, 0)
            self.assertEqual(file_hash(run / "best.pt"), digest)

    def test_baseline_option_replaces_default_checkpoint(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            env = self.environment(SI_LLM_CONFIG=str(tiny_config(root)),
                                   SI_LLM_CSV_ROOT=str(collection(root)), SI_LLM_DATA=str(root / "data"),
                                   SI_LLM_RUN=str(root / "missing run"), SI_LLM_REPORT_ROOT=str(root / "reports"),
                                   SI_LLM_DEVICE="cpu", SI_LLM_THREADS="2")
            result = self.execute("data.sh", root, env)
            self.assertEqual(result.returncode, 0, result.stderr)
            for script, option in (("validation.sh", ["--baseline", "literal"]),
                                   ("test.sh", ["--baseline=literal"])):
                result = self.execute(script, root, env, *option)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse((root / "missing run").exists())
