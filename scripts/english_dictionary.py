#!/usr/bin/env python3
"""Maintain SI's English dictionary using the same SQLite and overlay contract as Chinese."""

import argparse
import gzip
import json
import math
import os
from pathlib import Path
import re
import sqlite3
import tempfile

import lexicon_database as lexicon
from msime_dictionary import digest, write_atomic
import ranking
import vocabulary

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / "Data/English/SI"
RESOURCES = ROOT / "mac/SI/Core/Resources/English"


def validate_reading(text, reading):
    if not re.fullmatch(r"[A-Za-z]{1,64}", text) or reading != text.lower():
        raise ValueError("English entries require 1–64 ASCII letters and their exact lowercase reading")


def snapshot():
    """Explicit offline adoption of the retained, attributed English import materials."""
    outputs, summary = vocabulary.compile_vocabulary(ROOT)
    words = [line.split("\t")[0] for line in outputs[vocabulary.MERGED].decode().splitlines()[1:]]
    frequencies = [10 ** (-value / 100) for value in ranking.frequency_bins(words)]
    # Pin the conversion once, independently of future SI additions/deletions. Existing
    # Chinese weights already define this reference unit; do not rescale them on rebuild.
    total = math.fsum(frequencies) + 1e-9
    mass = lexicon.FORMAT["reference_mass"]
    weights = [max(1, round(value / total * mass)) for value in frequencies]
    raw = ("# text\treading\tweight (si-relative-frequency-v1)\n" + "".join(
        f"{word}\t{word.lower()}\t{weight}\n" for word, weight in zip(words, weights))).encode()
    notices = {"mac/SI/Resources/EnglishVocabularyNotices.txt": outputs[vocabulary.NOTICES],
               "mac/SI/Resources/RankingNotices.txt": ranking.notices().encode()}
    # Adoption requires the reviewable imports/notices to have been regenerated first.
    vocabulary.write_outputs(ROOT, outputs, check=True)
    for name, content in notices.items():
        if (ROOT / name).read_bytes() != content:
            raise ValueError("Regenerate retained import notices before snapshot: " + name)
    lock = {"schema_version": 1, "dictionary_format": lexicon.FORMAT,
            "sources": [{"path": "sources/english-base.txt.gz", "size": len(raw), "sha256": digest(raw)}],
            "bootstrap": {"vocabulary_inputs_sha256": summary["inputs_sha256"],
                          "vocabulary_words_sha256": summary["words_sha256"],
                          "wordfreq_source_sha256": digest((ranking.SOURCE / "source.json").read_bytes()),
                          "normalization_mass": total, "missing_frequency": 1e-9,
                          "conversion": "max(1, round(frequency / normalization_mass * reference_mass))"},
            "unknown_weight": max(1, round(1e-9 / total * mass)),
            "notices": {name: digest(content) for name, content in notices.items()}}
    write_atomic(DATA / "sources/english-base.txt.gz", gzip.compress(raw, mtime=0))
    write_atomic(DATA / "sources.lock.json", (json.dumps(lock, indent=2) + "\n").encode())
    print(f"Snapshotted {len(words)} English entries in the shared SI weight unit")


def build(check=False):
    lock = json.loads((DATA / "sources.lock.json").read_text())
    if lock.get("schema_version") != 1 or lock.get("dictionary_format") != lexicon.FORMAT:
        raise ValueError("Unsupported English source lock or dictionary format")
    unknown_weight = lock.get("unknown_weight")
    if type(unknown_weight) is not int or not 1 <= unknown_weight <= 2**63 - 1:
        raise ValueError("Invalid English unknown weight")
    entries = lexicon.overlay_entries(DATA / "si-entries.json", validate_reading)
    for name, checksum in lock["notices"].items():
        path = Path(name)
        if path.is_absolute() or ".." in path.parts or digest((ROOT / path).read_bytes()) != checksum:
            raise ValueError("English notice checksum mismatch: " + name)
    RESOURCES.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(dir=RESOURCES, suffix=".sqlite")
    os.close(descriptor)
    connection = None
    try:
        connection = sqlite3.connect(temporary)
        lexicon.create_schema(connection, unknown_weight=unknown_weight)
        imported = 0
        for source in lock["sources"]:
            path = Path(source["path"])
            if path.is_absolute() or ".." in path.parts:
                raise ValueError("Source path must stay inside the dictionary directory")
            content = gzip.decompress((DATA / path).read_bytes())
            if len(content) != source["size"] or digest(content) != source["sha256"]:
                raise ValueError("Source checksum mismatch: " + source["path"])
            for line in content.decode("utf-8-sig").splitlines():
                if not line or line.startswith("#"):
                    continue
                columns = line.split("\t")
                if len(columns) != 3:
                    raise ValueError("English sources require text, reading and weight")
                text, reading, weight = columns
                validate_reading(text, reading)
                weight = int(weight)
                if not 0 <= weight <= 2**63 - 1:
                    raise ValueError("Invalid source weight")
                table = lexicon.table_for(reading)
                imported += 1
                connection.execute(f"INSERT INTO {table} (rowid,key,jp,value,weight) VALUES (?,?,?,?,?) "
                                   "ON CONFLICT(key,value) DO UPDATE SET weight=excluded.weight "
                                   "WHERE excluded.weight>weight", (imported, reading, reading[0], text, weight))
        lexicon.apply_overlay(connection, entries)
        for table in lexicon.TABLES:
            if connection.execute(f"SELECT key FROM {table} GROUP BY key HAVING count(*)>1 LIMIT 1").fetchone():
                raise ValueError("English readings must be unique; exclude the old casing before replacing it")
        count = lexicon.finish_schema(connection)
        if count == 0:
            raise ValueError("English dictionary must not be empty")
        # A reviewable view of the effective database, including public SI edits.
        query = " UNION ALL ".join(f"SELECT value,key,weight FROM {table}" for table in lexicon.TABLES)
        query += " ORDER BY weight DESC,key COLLATE BINARY ASC,value COLLATE BINARY ASC"
        readable = ("text\treading\tweight\n" + "".join(
            f"{text}\t{reading}\t{weight}\n" for text, reading, weight in connection.execute(query))).encode()
        readable_path = DATA / "generated/weights.tsv"
        connection.close()
        manifest = {**lock, "input_rows": imported, "entries": count,
                    "runtime_sha256": digest(Path(temporary).read_bytes()),
                    "si_overlay_sha256": digest((DATA / "si-entries.json").read_bytes())}
        target = RESOURCES / "si-english.sqlite"
        manifest_path = RESOURCES / "dictionary-manifest.json"
        if check:
            if not target.exists():
                raise ValueError("Generated dictionary is out of date; run build")
            actual_hash = digest(target.read_bytes())
            if actual_hash != manifest["runtime_sha256"] and not lexicon.same_dictionary(temporary, target):
                raise ValueError("Generated dictionary is out of date; run build")
            manifest["runtime_sha256"] = actual_hash
            if not manifest_path.exists() or json.loads(manifest_path.read_text()) != manifest:
                raise ValueError("Generated dictionary manifest is out of date; run build")
            if not readable_path.exists() or readable_path.read_bytes() != readable:
                raise ValueError("Readable weights are out of date; run build")
        else:
            os.replace(temporary, target)
            target.chmod(0o644)
            write_atomic(manifest_path, (json.dumps(manifest, indent=2) + "\n").encode())
            write_atomic(readable_path, readable)
        print(f"{'Checked' if check else 'Wrote'} SI English dictionary: {count} entries")
    finally:
        if connection is not None:
            connection.close()
        Path(temporary).unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("snapshot", help="Explicitly adopt the retained English imports and wordfreq weights, offline")
    sub.add_parser("build", help="Build the maintained dictionary, offline").add_argument("--check", action="store_true")
    args = parser.parse_args()
    try:
        snapshot() if args.command == "snapshot" else build(args.check)
    except (ValueError, OSError, KeyError, sqlite3.DatabaseError) as error:
        parser.exit(1, f"English dictionary error: {error}\n")


if __name__ == "__main__":
    main()
