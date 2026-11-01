import csv
import hashlib
import importlib.util
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("input_history", ROOT / "scripts/input_history.py")
history = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(history)


def archive(path, rows):
    header = {"type": "manifest", "format": "si-input-history", "version": 1,
              "scope": "all_saved_history", "exported_at_unix": 1000.125}
    lines = [json.dumps(header, ensure_ascii=False).encode() + b"\n"]
    lines += [json.dumps(row, ensure_ascii=False).encode() + b"\n" for row in rows]
    summary = {"type": "summary", "record_count": len(rows), "sha256": hashlib.sha256(b"".join(lines)).hexdigest()}
    path.write_bytes(b"".join(lines) + json.dumps(summary).encode() + b"\n")


def row(sequence=1, **overrides):
    return {"type": "entry", "sequence": sequence, "id": str(uuid.uuid4()).upper(),
            "created_at_unix": 1000.125, "input": "nihao", "output": "你好",
            "language": "zh-Hans", "mixed": False, "reason": "explicitSelection", **overrides}


class InputHistoryToolsTests(unittest.TestCase):
    def test_restore_preserves_repeats_unicode_nulls_gaps_and_old_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "history.jsonl"
            text = "e\u0301\0中\n\" "
            rows = [row(1, input="lu:se'", output=text), row(7, input="lu:se'", output=text)]
            archive(source, rows)
            output = root / "restored.sqlite3"
            result = history.restore(source, output)
            self.assertEqual(result["record_count"], 2)
            with sqlite3.connect(output) as database:
                values = database.execute("SELECT sequence, input, output FROM input_history ORDER BY sequence").fetchall()
                self.assertEqual(database.execute("PRAGMA user_version").fetchone()[0], 1)
            self.assertEqual(values, [(1, "lu:se'", text), (7, "lu:se'", text)])
            self.assertEqual(output.stat().st_mode & 0o777, 0o600)
            original = output.read_bytes()
            with self.assertRaises(history.HistoryError):
                history.restore(source, output)
            self.assertEqual(output.read_bytes(), original)

    def test_corrupt_truncated_duplicate_and_future_exports_publish_nothing(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "history.jsonl"
            archive(source, [row()])
            valid = source.read_bytes()
            broken = [valid.replace(b"nihao", b"wrong"), valid.rsplit(b"\n", 2)[0] + b"\n", valid + b"\n",
                      valid.replace(b'"version": 1', b'"version": 99'), valid.replace(b'"record_count": 1', b'"record_count": 2'), valid.replace(b'"language": "zh-Hans"', b'"language": NaN')]
            for index, data in enumerate(broken):
                source.write_bytes(data)
                destination = root / f"invalid{index}.sqlite3"
                with self.assertRaises(history.HistoryError):
                    history.restore(source, destination)
                self.assertFalse(destination.exists())
            repeated = row()
            archive(source, [repeated, {**repeated, "sequence": 2}])
            with self.assertRaises(history.HistoryError):
                history.restore(source, root / "duplicate.sqlite3")
            self.assertFalse((root / "duplicate.sqlite3").exists())

    def test_export_prepares_candidates_without_purpose_flags_and_keeps_observations_unsplit(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "history.jsonl"
            rows = [row(), row(2, input="Hello", output="Hello ", language="en", reason="defaultAcceptance"),
                    row(3, reason="automaticConfirmation"), row(4, input="raw", output="raw", language=None, reason="literal"),
                    row(5, output="private\0control")]
            archive(source, rows)
            output = root / "candidates"
            report = history.prepare(source, output)
            self.assertEqual(report["candidate_rows"], 2)
            self.assertEqual(report["record_count"], 5)
            self.assertNotIn("allow_model_training", report)
            self.assertNotIn("training_notice_version", report)
            self.assertEqual(report["splits"], "unassigned")
            self.assertEqual(report["excluded_rows"], {"commit_reason": 2, "training_text_limits": 1})
            with (output / "candidates.csv").open(newline="") as stream:
                values = list(csv.DictReader(stream))
            self.assertEqual(values, [{"input": "nihao", "target": "你好", "language": "zh"},
                                      {"input": "Hello", "target": "Hello ", "language": "en"}])
            self.assertEqual((output / "candidates.csv").stat().st_mode & 0o777, 0o600)
            with_literals = history.prepare(source, root / "with-literals", include_literal=True)
            self.assertEqual(with_literals["candidate_rows"], 3)
            with self.assertRaises(history.HistoryError):
                history.prepare(source, output)

    def test_more_than_five_thousand_entries_restore_without_dedup_or_age_filter(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "history.jsonl"
            archive(source, [row(index + 1) for index in range(5005)])
            output = root / "restored.sqlite3"
            history.restore(source, output)
            with sqlite3.connect(output) as database:
                self.assertEqual(database.execute("SELECT count(*) FROM input_history").fetchone()[0], 5005)


if __name__ == "__main__":
    unittest.main()
