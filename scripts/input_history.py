#!/usr/bin/env python3
"""Validate, restore, and prepare explicitly shared SI history without printing private text."""
import argparse
from collections import Counter
import contextlib
import csv
import hashlib
import json
import math
import os
from pathlib import Path
import sqlite3
import tempfile
import unicodedata
import uuid

MAX_LINE_BYTES = 64 * 1024 * 1024 + 1  # Includes the terminating LF.
REASONS = {"explicitSelection", "defaultAcceptance", "automaticConfirmation", "literal", "focusChange", "passthrough"}
SCHEMA = """CREATE TABLE input_history (
sequence INTEGER PRIMARY KEY AUTOINCREMENT, event_id TEXT NOT NULL UNIQUE,
created_at REAL NOT NULL, input TEXT NOT NULL, output TEXT NOT NULL,
language TEXT, mixed INTEGER NOT NULL, reason TEXT NOT NULL)"""


class HistoryError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise HistoryError(message)


def finite_number(value):
    return type(value) in (int, float) and math.isfinite(value)


def json_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "Duplicate JSON field.")
        result[key] = value
    return result


def reject_constant(_):
    raise HistoryError("Nonfinite JSON constant.")


def decode_line(raw, number):
    require(raw.endswith(b"\n") and len(raw) <= MAX_LINE_BYTES, f"Truncated or oversized JSONL line {number}.")
    try:
        value = json.loads(raw.decode("utf-8"), object_pairs_hook=json_object,
                           parse_constant=reject_constant)
    except (ValueError, UnicodeError):
        raise HistoryError(f"Invalid JSON at line {number}.") from None
    require(type(value) is dict, f"Expected an object at line {number}.")
    return value


def validate_into(archive, database):
    """One streaming validation pass; SQLite enforces UUID/sequence uniqueness without an in-memory ID set."""
    digest = hashlib.sha256()
    file_digest = hashlib.sha256()
    count = 0
    last_sequence = 0
    reasons = Counter()
    with Path(archive).open("rb") as stream:
        raw = stream.readline(MAX_LINE_BYTES + 1)
        header = decode_line(raw, 1)
        require(set(header) == {"type", "format", "version", "scope", "exported_at_unix"}, "Invalid manifest fields.")
        require(header["type"] == "manifest" and header["format"] == "si-input-history"
                and type(header["version"]) is int and header["version"] == 1, "Unsupported export format or version.")
        require(header["scope"] == "all_saved_history" and finite_number(header["exported_at_unix"]), "Invalid manifest scope or time.")
        digest.update(raw)
        file_digest.update(raw)
        while True:
            raw = stream.readline(MAX_LINE_BYTES + 1)
            row = decode_line(raw, count + 2)
            file_digest.update(raw)
            if row.get("type") == "summary":
                require(set(row) == {"type", "record_count", "sha256"}, "Invalid summary fields.")
                require(type(row["record_count"]) is int and row["record_count"] == count, "Record count differs from summary.")
                require(row["sha256"] == digest.hexdigest(), "Export checksum differs from summary.")
                require(stream.read(1) == b"", "Unexpected data after summary.")
                break
            require(set(row) == {"type", "sequence", "id", "created_at_unix", "input", "output", "language", "mixed", "reason"}
                    and row["type"] == "entry", "Invalid history entry fields.")
            require(type(row["sequence"]) is int and last_sequence < row["sequence"] < 2**63, "Entry sequences must strictly increase.")
            require(type(row["id"]) is str, "Invalid event identity.")
            try:
                canonical_id = str(uuid.UUID(row["id"])).upper()
            except ValueError:
                raise HistoryError("Invalid event identity.") from None
            require(canonical_id == row["id"], "Event identity is not a canonical UUID.")
            require(finite_number(row["created_at_unix"]), "Invalid entry time.")
            require(type(row["input"]) is str and row["input"] and type(row["output"]) is str and row["output"], "Empty or invalid source/output.")
            try:
                row["input"].encode("utf-8")
                row["output"].encode("utf-8")
            except UnicodeError:
                raise HistoryError("Entry text is not valid Unicode.") from None
            require(row["language"] in (None, "en", "zh-Hans") and type(row["mixed"]) is bool, "Invalid language metadata.")
            require(not row["mixed"] or row["language"] == "zh-Hans", "Invalid mixed-language identity.")
            require(type(row["reason"]) is str and row["reason"] in REASONS, "Invalid commit reason.")
            try:
                database.execute("INSERT INTO input_history VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                                 (row["sequence"], row["id"], row["created_at_unix"], row["input"], row["output"],
                                  row["language"], int(row["mixed"]), row["reason"]))
            except sqlite3.Error:
                raise HistoryError("Duplicate event identity or invalid database record.") from None
            last_sequence = row["sequence"]
            count += 1
            reasons[row["reason"]] += 1
            digest.update(raw)
    database.commit()
    return {"format": "si-input-history", "version": 1, "record_count": count,
            "archive_sha256": file_digest.hexdigest(), "reasons": dict(reasons)}


@contextlib.contextmanager
def validated_archive(archive, directory=None):
    with tempfile.TemporaryDirectory(prefix="si-history-", dir=directory) as temporary:
        path = Path(temporary) / "history.sqlite3"
        path.touch(mode=0o600)
        database = sqlite3.connect(path)
        try:
            database.execute(SCHEMA)
            database.execute("PRAGMA user_version = 1")
            metadata = validate_into(archive, database)
            yield path, database, metadata
        finally:
            database.close()


def restore(archive, output):
    output = Path(output)
    require(not os.path.lexists(output), "Destination already exists; choose a new database path.")
    require(output.parent.is_dir(), "Destination directory does not exist.")
    with validated_archive(archive, output.parent) as (path, database, metadata):
        # No-clobber publication is atomic, even if another process creates the destination during validation.
        database.close()
        os.link(path, output)
        return metadata


def prepare(archive, output, include_literal=False):
    output = Path(output)
    require(not os.path.lexists(output), "Destination already exists; choose a new candidate-data directory.")
    require(output.parent.is_dir(), "Destination directory does not exist.")
    with validated_archive(archive, output.parent) as (_, database, metadata):
        with tempfile.TemporaryDirectory(prefix="si-history-candidates-", dir=output.parent) as temporary:
            directory = Path(temporary)
            csv_path = directory / "candidates.csv"
            rejected = Counter()
            count = 0
            with csv_path.open("x", encoding="utf-8", newline="") as target:
                os.chmod(csv_path, 0o600)
                writer = csv.writer(target)
                writer.writerow(["input", "target", "language"])
                for spelling, text, language, mixed, reason in database.execute(
                        "SELECT input, output, language, mixed, reason FROM input_history ORDER BY sequence"):
                    if reason not in {"explicitSelection", "defaultAcceptance"} and not (include_literal and reason == "literal"):
                        rejected["commit_reason"] += 1
                        continue
                    if language is None:
                        if include_literal and reason == "literal" and spelling.isascii() and text.isascii():
                            language = "en"
                        else:
                            rejected["unknown_language"] += 1
                            continue
                    if any(not value.strip() or len(value.encode("utf-8")) > 4096
                           or any(unicodedata.category(c) in ("Cc", "Cs") for c in value) for value in (spelling, text)):
                        rejected["training_text_limits"] += 1
                        continue
                    writer.writerow([spelling, text, "mixed" if mixed else "zh" if language == "zh-Hans" else "en"])
                    count += 1
            report = {**metadata, "candidate_rows": count, "excluded_rows": dict(rejected),
                      "include_ascii_literal": include_literal, "preparation_version": 1,
                      "csv_sha256": file_hash(csv_path), "status": "unreviewed-observations-not-gold-labels",
                      "splits": "unassigned", "rights": "not-declared-by-export"}
            report_path = directory / "provenance.json"
            with report_path.open("x", encoding="utf-8") as target:
                os.chmod(report_path, 0o600)
                json.dump(report, target, indent=2, ensure_ascii=False)
                target.write("\n")
            # Copy no files until validation/CSV preparation succeeds.
            output.mkdir(mode=0o700)
            try:
                os.rename(csv_path, output / csv_path.name)
                os.rename(report_path, output / report_path.name)
            except BaseException:
                for path in output.iterdir():
                    path.unlink()
                output.rmdir()
                raise
            return report


def file_hash(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for command in ("inspect", "restore", "prepare"):
        sub = commands.add_parser(command)
        sub.add_argument("archive", type=Path)
        if command != "inspect":
            sub.add_argument("--output", type=Path, required=True)
        if command == "prepare":
            sub.add_argument("--include-literal", action="store_true", help="Include observed ASCII literal/copy tasks, still subject to review.")
    args = parser.parse_args(argv)
    try:
        if args.command == "inspect":
            with validated_archive(args.archive) as (_, _, result):
                pass
        elif args.command == "restore":
            result = restore(args.archive, args.output)
        else:
            result = prepare(args.archive, args.output, args.include_literal)
    except (HistoryError, OSError, sqlite3.Error, OverflowError):
        # Never echo parser/SQLite/file errors that may include private input or paths.
        parser.exit(2, "Input history operation failed. Check the archive, checksum and a new writable destination.\n")
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
