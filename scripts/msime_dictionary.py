#!/usr/bin/env python3
"""Maintain SI's Chinese dictionary from pinned MSIME sources; no runtime downloads."""

import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import tempfile
import urllib.request

import lexicon_database as lexicon

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "Data/Chinese/MSIME"
RESOURCES = ROOT / "mac/SI/Core/Resources/Chinese"
INITIALS = "abcdefghjklmnopqrstwxyz"
SOURCES = ["sources/pinyin/single-chars.txt", "sources/pinyin/rime-ice.txt",
           "sources/pinyin/rime-ice-supplement.txt", "sources/pinyin/places.txt", "custom/words.txt"]


def digest(data):
    return hashlib.sha256(data).hexdigest()


def write_atomic(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(dir=path.parent, prefix=".incoming-")
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
        os.replace(temporary, path)
        path.chmod(0o644)
    finally:
        Path(temporary).unlink(missing_ok=True)


def snapshot(dictionary, engine):
    revision = subprocess.check_output(["git", "-C", str(dictionary), "rev-parse", "HEAD"], text=True).strip()
    engine_revision = subprocess.check_output(["git", "-C", str(engine), "rev-parse", "HEAD"], text=True).strip()
    records = []
    for source in SOURCES:
        content = (dictionary / source).read_bytes()
        target = "sources/" + source.replace("/", "-") + ".gz"
        write_atomic(DATA / target, gzip.compress(content, mtime=0))
        records.append({"path": target, "upstream_path": source, "sha256": digest(content), "size": len(content)})
    corrections = (engine / "resources/dictionary-sources/pinyin-reading-corrections.txt").read_bytes()
    write_atomic(DATA / "reading-corrections.tsv", corrections)
    lock = {"schema_version": 1, "dictionary_repository": "https://github.com/metasequoiaime/msime-dictionary",
            "dictionary_revision": revision, "engine_repository": "https://github.com/metasequoiaime/msime",
            "engine_revision": engine_revision, "sources": records,
            "corrections_sha256": digest(corrections)}
    write_atomic(DATA / "sources.lock.json", (json.dumps(lock, indent=2) + "\n").encode())


def table_for(reading):
    syllables = reading.split("'")
    if not syllables or not re.fullmatch(r"[a-z]+(?:'[a-z]+)*", reading):
        raise ValueError("Invalid explicit Pinyin reading")
    if syllables[0][0] not in INITIALS:
        return None
    return lexicon.table_for(reading)


def overlay_entries():
    def validate_reading(text, reading):
        if table_for(reading) is None:
            raise ValueError("Unsupported SI reading")
    return lexicon.overlay_entries(DATA / "si-entries.json", validate_reading)


same_dictionary = lexicon.same_dictionary


def build(check=False):
    lock = json.loads((DATA / "sources.lock.json").read_text())
    entries = overlay_entries()
    RESOURCES.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(dir=RESOURCES, suffix=".sqlite")
    os.close(descriptor)
    connection = None
    try:
        connection = sqlite3.connect(temporary)
        lexicon.create_schema(connection)
        tables = lexicon.TABLES
        imported = 0
        for source in lock["sources"]:
            content = gzip.decompress((DATA / source["path"]).read_bytes())
            if len(content) != source["size"] or digest(content) != source["sha256"]:
                raise ValueError("Source checksum mismatch: " + source["path"])
            for number, line in enumerate(content.decode("utf-8-sig").splitlines(), 1):
                if not line or line.startswith("#"):
                    continue
                columns = line.strip().split("\t")
                if len(columns) < 3:
                    raise ValueError(f"{source['path']}:{number}: missing explicit reading or weight")
                text, reading, weight = columns[:3]
                # Upstream excludes readings outside its plain Latin table contract.
                if not re.fullmatch(r"[a-z]+(?:'[a-z]+)*", reading):
                    continue
                table = table_for(reading)
                if table is None or not text:
                    continue
                weight = int(weight)
                if weight < 0:
                    raise ValueError("Negative source weight")
                initials = "".join(s[0] for s in reading.split("'"))
                imported += 1
                # The three lexical tables retain the source row that wins weight/rowid
                # deduplication. Upstream additions raise an existing row in place.
                addition = source["upstream_path"] in ("sources/pinyin/places.txt", "custom/words.txt")
                update = 'weight=excluded.weight' + ('' if addition else ',rowid=excluded.rowid')
                connection.execute(f'INSERT INTO {table} (rowid,key,jp,value,weight) VALUES (?,?,?,?,?) '
                                   f'ON CONFLICT(key,value) DO UPDATE SET {update} WHERE excluded.weight>weight',
                                   (imported, reading, initials, text, weight))
        corrections = (DATA / "reading-corrections.tsv").read_bytes()
        if digest(corrections) != lock["corrections_sha256"]:
            raise ValueError("Reading correction checksum mismatch")
        for line in corrections.decode().splitlines():
            if not line or line.startswith("#"):
                continue
            text, wrong, correct = line.split("\t")
            table = table_for(wrong)
            connection.execute(f'DELETE FROM {table} WHERE key=? AND value=?', (wrong, text))
            table = table_for(correct)
            if not connection.execute(f'SELECT 1 FROM {table} WHERE key=? AND value=?', (correct, text)).fetchone():
                raise ValueError("Reading correction would remove every correct reading")
        # SI owns this overlay. It never changes upstream snapshots or their provenance.
        overlay = DATA / "si-entries.json"
        lexicon.apply_overlay(connection, entries)
        count = lexicon.finish_schema(connection)
        connection.close()
        manifest = {**lock, "dictionary_format": lexicon.FORMAT, "input_rows": imported, "entries": count,
                    "runtime_sha256": digest(Path(temporary).read_bytes()),
                    "si_overlay_sha256": digest(overlay.read_bytes())}
        manifest_bytes = (json.dumps(manifest, indent=2) + "\n").encode()
        target = RESOURCES / "si-pinyin.sqlite"
        manifest_path = RESOURCES / "dictionary-manifest.json"
        if check:
            if not target.exists():
                raise ValueError("Generated dictionary is out of date; run build")
            actual_hash = digest(target.read_bytes())
            if actual_hash != manifest["runtime_sha256"] and not same_dictionary(temporary, target, tables):
                raise ValueError("Generated dictionary is out of date; run build")
            # Validate the retained binary hash while allowing another SQLite version to
            # reproduce equivalent data/indexes with a different physical representation.
            manifest["runtime_sha256"] = actual_hash
            if not manifest_path.exists() or json.loads(manifest_path.read_text()) != manifest:
                raise ValueError("Generated dictionary manifest is out of date; run build")
        else:
            os.replace(temporary, target)
            target.chmod(0o644)
            write_atomic(manifest_path, manifest_bytes)
        print(f"{'Checked' if check else 'Wrote'} SI Chinese dictionary: {count} entries")
    finally:
        if connection is not None:
            connection.close()
        Path(temporary).unlink(missing_ok=True)


def verify_context():
    lock = json.loads((DATA / "resources.lock.json").read_text())
    for artifact in lock["artifacts"]:
        target = RESOURCES / artifact["name"]
        if (not target.exists() or target.stat().st_size != artifact["size"]
                or digest(target.read_bytes()) != artifact["sha256"]):
            raise ValueError("Context checksum mismatch: " + artifact["name"])
    print("Checked pinned MSIME context resources")


def audit():
    """Read upstream commit metadata only; never adopt an update automatically."""
    lock = json.loads((DATA / "sources.lock.json").read_text())
    sources = []
    for kind in ("dictionary", "engine"):
        repository = lock[kind + "_repository"]
        slug = repository.removeprefix("https://github.com/")
        request = urllib.request.Request("https://api.github.com/repos/" + slug + "/commits/HEAD",
                                         headers={"User-Agent": "SI-dictionary-maintenance"})
        if os.environ.get("GITHUB_TOKEN"):
            request.add_header("Authorization", "Bearer " + os.environ["GITHUB_TOKEN"])
        with urllib.request.urlopen(request, timeout=30) as response:
            latest = json.load(response)["sha"]
        pinned = lock[kind + "_revision"]
        sources.append({"source": kind, "pinned_revision": pinned, "latest_revision": latest,
                        "update_available": latest != pinned,
                        "compare_url": repository + "/compare/" + pinned + "..." + latest})
    return {"schema_version": 1, "sources": sources}


def fetch_context():
    lock = json.loads((DATA / "resources.lock.json").read_text())
    for artifact in lock["artifacts"]:
        if artifact["name"] not in ("msime-bigram.bin", "msime-trigram.bin"):
            continue
        target = RESOURCES / artifact["name"]
        if target.exists() and target.stat().st_size == artifact["size"] and digest(target.read_bytes()) == artifact["sha256"]:
            continue
        request = urllib.request.Request(artifact["url"], headers={"User-Agent": "SI-dictionary-maintenance"})
        with urllib.request.urlopen(request, timeout=90) as response:
            content = response.read(artifact["size"] + 1)
        if len(content) != artifact["size"] or digest(content) != artifact["sha256"]:
            raise ValueError("Context artifact checksum mismatch")
        write_atomic(target, content)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    command = sub.add_parser("snapshot")
    command.add_argument("--dictionary", type=Path, required=True)
    command.add_argument("--engine", type=Path, required=True)
    command = sub.add_parser("build", help="Build the SQLite dictionary offline")
    command.add_argument("--check", action="store_true", help="Check generated files without replacing them")
    sub.add_parser("fetch-context")
    command = sub.add_parser("audit", help="Read upstream revisions without adopting changes")
    command.add_argument("--report", type=Path)
    args = parser.parse_args()
    if args.command == "snapshot":
        snapshot(args.dictionary, args.engine)
    elif args.command == "build":
        build(args.check)
        if args.check:
            verify_context()
    elif args.command == "fetch-context":
        fetch_context()
    else:
        report = (json.dumps(audit(), indent=2) + "\n").encode()
        if args.report:
            write_atomic(args.report, report)
        print(report.decode(), end="")


if __name__ == "__main__":
    main()
