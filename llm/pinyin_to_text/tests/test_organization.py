"""Verify model-folder relocation preserves actual commands and resume behavior."""

import contextlib
import importlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from llm.pinyin_to_text.csv_data.prepare import prepare
from llm.pinyin_to_text.tests.helpers import ROOT, collection, tiny_config
from llm.pinyin_to_text.train import code_identity, train


class OrganizationTests(unittest.TestCase):
    def test_legacy_checkpoint_resumes_through_model_namespace(self):
        legacy = importlib.import_module("llm.train")
        self.assertEqual(legacy.code_identity(), code_identity())
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = tiny_config(root)
            prepare(config, collection(root), root / "data")
            with contextlib.redirect_stdout(io.StringIO()):
                legacy.train(config, root / "data", root / "run", "cpu", max_steps=1, threads=2)
                result = train(config, root / "data", root / "run", "cpu",
                               resume=True, max_steps=2, threads=2)
            self.assertEqual(result["step"], 2)

    def test_legacy_script_resolves_model_paths_from_another_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            recorder = root / "record-python"
            recorder.write_text(f"#!{sys.executable}\nimport json, sys\nprint(json.dumps(sys.argv[1:]))\n")
            recorder.chmod(0o755)
            environment = {key: value for key, value in os.environ.items() if not key.startswith("SI_LLM_")}
            environment["SI_LLM_PYTHON"] = str(recorder)
            result = subprocess.run([str(ROOT.parent / "scripts/data.sh")], cwd=root,
                                    env=environment, capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            arguments = json.loads(result.stdout)
            self.assertEqual(arguments[:2], ["-m", "llm.pinyin_to_text.csv_data.prepare"])
            self.assertEqual(arguments[arguments.index("--output") + 1],
                             str(ROOT / "data/prepared/pinyin-lexical-v1"))
            self.assertTrue((ROOT.parent / "configs/small-pinyin.json").samefile(ROOT / "configs/small-pinyin.json"))
