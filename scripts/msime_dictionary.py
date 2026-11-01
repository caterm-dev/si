#!/usr/bin/env python3
"""Compile SI Chinese CSV and maintain separately pinned MSIME context resources."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import tempfile
import urllib.request


ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "Data/Chinese/MSIME"
RESOURCES = DATA / "artifacts"
METADATA = ROOT / "Data/Vocabulary/meta.json"


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


def build(check=False):
    """Compatibility entry point; public lexical edits now live only in CSV."""
    from csv_dictionary import build as build_csv
    build_csv(check=check, language="chinese")


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
    records = json.loads(METADATA.read_text())["upstreams"]
    lock = next(record["metadata"] for record in records if record["id"] == "chinese-bootstrap")
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
    command = sub.add_parser("build", help="Build the SQLite dictionary offline")
    command.add_argument("--check", action="store_true", help="Check generated files without replacing them")
    sub.add_parser("fetch-context")
    command = sub.add_parser("audit", help="Read upstream revisions without adopting changes")
    command.add_argument("--report", type=Path)
    args = parser.parse_args()
    if args.command == "build":
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
