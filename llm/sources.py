"""Register checksum-pinned, explicitly licensed local public corpora."""

import argparse
import os
from pathlib import Path

from .common import file_hash, read_json, read_jsonl, write_json


def load_sources(manifest_path):
    manifest_path = Path(manifest_path)
    manifest = read_json(manifest_path)
    if manifest.get("schema_version") != 1 or not manifest.get("sources"):
        raise ValueError("Expected a version 1 manifest with sources")
    seen = set()
    for source in manifest["sources"]:
        for key in ("id", "path", "sha256", "license", "origin", "revision", "format"):
            if not isinstance(source.get(key), str) or not source[key].strip():
                raise ValueError(f"Source requires nonempty {key}")
        if source["id"] in seen:
            raise ValueError("Duplicate source ID")
        seen.add(source["id"])
        if source["format"] not in ("pairs", "text"):
            raise ValueError("Source format must be pairs or text")
        path = manifest_path.parent / source["path"]
        if file_hash(path) != source["sha256"]:
            raise ValueError(f"Source checksum mismatch: {source['id']}")
        yield source, read_jsonl(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--path", type=Path, required=True)
    parser.add_argument("--id", required=True)
    parser.add_argument("--license", required=True, help="Reviewed SPDX identifier or LicenseRef")
    parser.add_argument("--origin", required=True, help="Public origin URL or SI-authored fixture description")
    parser.add_argument("--revision", required=True, help="Pinned upstream revision/date and extraction version")
    parser.add_argument("--format", choices=("pairs", "text"), required=True)
    args = parser.parse_args()
    manifest = read_json(args.manifest) if args.manifest.exists() else {"schema_version": 1, "sources": []}
    if any(s["id"] == args.id for s in manifest["sources"]):
        parser.error("Source ID already exists; review and edit the manifest explicitly")
    source = {
        "id": args.id, "path": os.path.relpath(args.path.resolve(), args.manifest.parent.resolve()),
        "sha256": file_hash(args.path), "license": args.license, "origin": args.origin,
        "revision": args.revision, "format": args.format,
    }
    for value in source.values():
        if not value.strip():
            parser.error("Source fields must not be blank")
    manifest["sources"].append(source)
    write_json(args.manifest, manifest)
    print(f"Registered {args.id}; no data was downloaded or uploaded.")


if __name__ == "__main__":
    main()
