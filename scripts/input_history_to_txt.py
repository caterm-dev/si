#!/usr/bin/env python3
"""Extract submitted text from SI history JSONL into adjacent UTF-8 TXT files."""

import argparse
import hashlib
import os
from pathlib import Path
import tempfile

if __package__:
    from .input_history import HistoryError, MAX_LINE_BYTES, decode_line, finite_number, require
else:
    from input_history import HistoryError, MAX_LINE_BYTES, decode_line, finite_number, require

DEFAULT_DIRECTORY = Path(__file__).resolve().parents[1] / "corpus/chinese/raw/input-history"
SCOPES = {"si-sentence-history": "all_saved_sentences", "si-input-history": "all_saved_history"}
ENTRY_FIELDS = {"type", "sequence", "id", "created_at_unix", "output"}


def extract(source, target):
    """Stream output fields verbatim, validating the envelope before publication."""
    digest = hashlib.sha256()
    count = last_sequence = 0
    with source.open("rb") as stream:
        raw = stream.readline(MAX_LINE_BYTES + 1)
        header = decode_line(raw, 1)
        require(set(header) == {"type", "format", "version", "scope", "exported_at_unix"},
                "Invalid manifest fields.")
        kind = header["format"]
        require(header["type"] == "manifest" and type(kind) is str and kind in SCOPES
                and type(header["version"]) is int and header["version"] == 1,
                "Unsupported history format or version.")
        require(header["scope"] == SCOPES[kind] and finite_number(header["exported_at_unix"]),
                "Invalid manifest scope or time.")
        fields = ENTRY_FIELDS if kind == "si-sentence-history" else ENTRY_FIELDS | {
            "input", "language", "mixed", "reason"}
        digest.update(raw)
        while True:
            raw = stream.readline(MAX_LINE_BYTES + 1)
            row = decode_line(raw, count + 2)
            if row.get("type") == "summary":
                require(set(row) == {"type", "record_count", "sha256"}, "Invalid summary fields.")
                require(type(row["record_count"]) is int and row["record_count"] == count,
                        "Record count differs from summary.")
                require(row["sha256"] == digest.hexdigest(), "Export checksum differs from summary.")
                require(stream.read(1) == b"", "Unexpected data after summary.")
                return count
            require(set(row) == fields and row["type"] == "entry", "Invalid entry fields.")
            require(type(row["sequence"]) is int and last_sequence < row["sequence"] < 2**63,
                    "Entry sequences must strictly increase.")
            require(type(row["output"]) is str and row["output"], "Empty or invalid output text.")
            target.write(row["output"])
            target.write("\n")
            last_sequence = row["sequence"]
            count += 1
            digest.update(raw)


def convert(source, overwrite=False):
    source = Path(source)
    require(source.suffix.lower() == ".jsonl", "Expected a JSONL history file.")
    destination = source.with_suffix(".txt")
    require(overwrite or not os.path.lexists(destination), "TXT already exists; use --overwrite to replace it.")
    descriptor, temporary = tempfile.mkstemp(prefix=".si-history-txt-", dir=source.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="") as target:
            count = extract(source, target)
            target.flush()
            os.fsync(target.fileno())
        if overwrite:
            os.replace(temporary, destination)
        else:
            # Refuse an existing destination even if another process creates it during extraction.
            os.link(temporary, destination)
        return destination, count
    finally:
        Path(temporary).unlink(missing_ok=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", nargs="?", type=Path, default=DEFAULT_DIRECTORY,
                        help="JSONL file or directory (default: corpus/chinese/raw/input-history).")
    parser.add_argument("--overwrite", action="store_true", help="Replace existing TXT files after successful validation.")
    args = parser.parse_args(argv)
    try:
        sources = sorted(args.source.glob("*.jsonl")) if args.source.is_dir() else [args.source]
        require(bool(sources), "No JSONL history files found.")
        for source in sources:
            destination, count = convert(source, overwrite=args.overwrite)
            print(f"{destination.name}: {count} records")
    except HistoryError as error:
        parser.exit(2, f"History text conversion failed: {error}\n")
    except (OSError, UnicodeError, ValueError, OverflowError):
        # Parser and I/O exceptions can contain private text; never echo them.
        parser.exit(2, "History text conversion failed. Check the archive and destination permissions.\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
