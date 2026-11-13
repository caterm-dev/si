#!/usr/bin/env python3
"""Audit the pinned MSIME upstream revisions."""

import argparse
import json
import os
from pathlib import Path
import tempfile
import urllib.request


ROOT = Path(__file__).resolve().parent.parent
METADATA = ROOT / "Data/Vocabulary/meta.json"


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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    command = sub.add_parser("audit", help="Read upstream revisions without adopting changes")
    command.add_argument("--report", type=Path)
    args = parser.parse_args()
    report = (json.dumps(audit(), indent=2) + "\n").encode()
    if args.report:
        write_atomic(args.report, report)
    print(report.decode(), end="")


if __name__ == "__main__":
    main()
