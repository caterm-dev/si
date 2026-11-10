import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from scripts import input_history_to_txt as converter


def archive(path, outputs, kind="si-sentence-history"):
    objects = [{"type": "manifest", "format": kind, "version": 1,
                "scope": converter.SCOPES[kind], "exported_at_unix": 1000}]
    for index, output in enumerate(outputs, 1):
        row = {"type": "entry", "sequence": index * 2, "id": f"event-{index}",
               "created_at_unix": 1000, "output": output}
        if kind == "si-input-history":
            row.update(input="nihao", language="zh-Hans", mixed=False, reason="explicitSelection")
        objects.append(row)
    data = b"".join((json.dumps(row, ensure_ascii=False) + "\n").encode() for row in objects)
    summary = {"type": "summary", "record_count": len(outputs), "sha256": hashlib.sha256(data).hexdigest()}
    path.write_bytes(data + (json.dumps(summary) + "\n").encode())


class InputHistoryTextTests(unittest.TestCase):
    def test_both_formats_extract_only_output_preserving_order_repeats_and_exact_text(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            outputs = ["你好", "你好", " e\u0301 👩🏽‍💻\t ", "两行\r\n正文\0"]
            for kind in converter.SCOPES:
                with self.subTest(kind=kind):
                    source = root / f"{kind}.jsonl"
                    archive(source, outputs, kind)
                    original = source.read_bytes()
                    destination, count = converter.convert(source)
                    self.assertEqual(count, 4)
                    self.assertEqual(destination, source.with_suffix(".txt"))
                    self.assertEqual(destination.read_bytes(), "".join(s + "\n" for s in outputs).encode())
                    self.assertEqual(destination.stat().st_mode & 0o777, 0o600)
                    self.assertEqual(source.read_bytes(), original)

    def test_corrupt_or_incomplete_archive_never_publishes_partial_text_or_replaces_previous_file(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "history.jsonl"
            archive(source, ["你好"])
            valid = source.read_bytes()
            broken = [valid.replace("你好".encode(), "再见".encode()), valid[:-10], valid + b"\n",
                      valid.replace(b'"record_count": 1', b'"record_count": 2'),
                      valid.replace(b'"version": 1', b'"version": 2')]
            destination = source.with_suffix(".txt")
            for data in broken:
                with self.subTest(data_length=len(data)):
                    source.write_bytes(data)
                    with self.assertRaises(converter.HistoryError):
                        converter.convert(source)
                    self.assertFalse(destination.exists())
                    destination.write_bytes(b"existing text\n")
                    with self.assertRaises(converter.HistoryError):
                        converter.convert(source, overwrite=True)
                    self.assertEqual(destination.read_bytes(), b"existing text\n")
                    destination.unlink()
                    self.assertEqual(sorted(p.name for p in source.parent.iterdir()), [source.name])

    def test_overwrite_requires_explicit_flag_and_empty_export_produces_empty_text(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "history.jsonl"
            archive(source, [])
            destination = source.with_suffix(".txt")
            destination.write_bytes(b"existing")
            with self.assertRaises(converter.HistoryError):
                converter.convert(source)
            self.assertEqual(destination.read_bytes(), b"existing")
            self.assertEqual(converter.convert(source, overwrite=True), (destination, 0))
            self.assertEqual(destination.read_bytes(), b"")


if __name__ == "__main__":
    unittest.main()
