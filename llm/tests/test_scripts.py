"""Exercise the shell entry points with real small-model training from another cwd."""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from llm.tests.helpers import ROOT


class ScriptTests(unittest.TestCase):
    def run_script(self, name, *args, cwd, extra_env=None, success=True):
        environment = {**os.environ, "SI_LLM_PYTHON": sys.executable}
        if extra_env:
            environment.update(extra_env)
        result = subprocess.run([str(ROOT / "scripts" / name), *map(str, args)], cwd=cwd,
                                env=environment, capture_output=True, text=True, timeout=90)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)
        return result

    def test_missing_environment_and_setup_preserve_existing_directories(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            missing = self.run_script("train.sh", cwd=directory,
                                      extra_env={"SI_LLM_PYTHON": "", "SI_LLM_VENV": str(directory / "missing")}, success=False)
            self.assertIn("setup.sh", missing.stderr)
            existing = directory / "keep this directory"
            existing.mkdir()
            marker = existing / "marker"
            marker.write_text("preserve", encoding="utf-8")
            result = self.run_script("setup.sh", "--python", sys.executable, "--venv", existing, cwd=directory, success=False)
            self.assertIn("not a virtual environment", result.stderr)
            self.assertEqual(marker.read_text(encoding="utf-8"), "preserve")
            self.run_script("setup.sh", "--help", cwd=directory)
            self.assertFalse((directory / "missing").exists())

    def test_shell_training_validation_test_and_inference(self):
        with tempfile.TemporaryDirectory(prefix="si-llm-scripts-") as temporary:
            directory = Path(temporary)
            data, run = directory / "prepared data", directory / "training run"
            self.run_script("prepare.sh", "--config", ROOT / "configs/smoke.json", "--output", data, cwd=directory)
            training = ["--config", ROOT / "configs/smoke.json", "--data", data, "--run", run,
                        "--device", "cpu", "--threads", "2"]
            self.run_script("train.sh", *training, "--max-steps", "2", cwd=directory)
            self.run_script("resume.sh", *training, "--max-steps", "3", cwd=directory)
            checkpoint = run / "best.pt"
            evaluation = ["--checkpoint", checkpoint, "--data", data, "--device", "cpu", "--threads", "2", "--limit", "1"]
            validation, test = directory / "validation.json", directory / "test.json"
            self.run_script("validation.sh", *evaluation, "--output", validation, cwd=directory)
            self.run_script("test.sh", *evaluation, "--output", test, cwd=directory)
            self.assertEqual(json.loads(validation.read_text())["split"], "validation")
            self.assertEqual(json.loads(test.read_text())["split"], "test")
            self.run_script("compare.sh", test, test, cwd=directory)
            exported = directory / "inference model.pt"
            self.run_script("export.sh", "--checkpoint", checkpoint, "--output", exported, cwd=directory)
            literal = "Test'$(touch SHOULD_NOT_EXIST)`echo unsafe`你好"
            result = self.run_script("infer.sh", "--checkpoint", exported, "--input", literal, "--device", "cpu", cwd=directory)
            self.assertIn(literal, json.loads(result.stdout)["candidates"])
            self.assertFalse((directory / "SHOULD_NOT_EXIST").exists())
            self.assertFalse((ROOT.parent / "SHOULD_NOT_EXIST").exists())
