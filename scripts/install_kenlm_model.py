#!/usr/bin/env python3
"""Verify and atomically select a local full-data KenLM model for SI."""
import argparse
import hashlib
import json
from pathlib import Path
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]


def stamp(path):
    state = path.stat()
    seconds, nanos = divmod(state.st_mtime_ns, 10**9)
    return {"bytes": state.st_size, "mtime_seconds": seconds, "mtime_nanos": nanos}


def install(binary, metadata, destination):
    metadata_bytes = metadata.read_bytes()
    data = json.loads(metadata_bytes)
    cleaning = data["cleaning"]
    model = data["model"]
    if (data["schema_version"] != 1 or data["kenlm"]["binary_format_version"] != 5
            or data["corpus"]["source_order"] != ["train", "heldout"]
            or cleaning["version"] != "si-kenlm-cleaning-v1"
            or cleaning["module_sha256"] != hashlib.sha256((ROOT / "scripts/kenlm_cleaning.py").read_bytes()).hexdigest()
            or cleaning["vectors_sha256"] != hashlib.sha256((ROOT / "Tests/KenLMTests/cleaning_vectors.json").read_bytes()).hexdigest()
            or cleaning["unicode_version"] != "15.0.0"
            or cleaning["maximum_scalars"] != 32 or cleaning["rare_threshold_exclusive"] != 5
            or model["order"] != 4 or model["a"] != 22 or model["prune"] != [0, 1, 2, 3]
            or model["probability_bits"] != 8 or model["backoff_bits"] != 8):
        raise ValueError("Incompatible full-data model metadata")
    destination.mkdir(parents=True, exist_ok=True, mode=0o700)
    with tempfile.TemporaryDirectory(prefix=".install-", dir=destination) as work:
        stage = Path(work)
        payload = stage / "payload"
        payload.mkdir(mode=0o700)
        target = payload / "final.bin"
        digest = hashlib.sha256()
        with binary.open("rb") as source, target.open("wb") as output:
            while chunk := source.read(1024 * 1024):
                output.write(chunk)
                digest.update(chunk)
        sha = digest.hexdigest()
        if sha != model["binary_sha256"] or target.stat().st_size != model["binary_bytes"]:
            raise ValueError("Model checksum or size does not match metadata")
        meta = payload / "final.meta.json"
        meta.write_bytes(metadata_bytes)
        target.chmod(0o400)
        meta.chmod(0o400)
        version = f"v1-{sha}-{uuid.uuid4().hex}"
        manifest = {"schema": 1, "version": version, "sha256": sha,
                    "model": stamp(target), "metadata": stamp(meta)}
        index = stage / "current.json"
        index.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        payload.rename(destination / version)
        index.replace(destination / "current.json")
    return destination / version


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", type=Path, default=ROOT / ".build/kenlm-final/final.bin")
    parser.add_argument("--metadata", type=Path, default=ROOT / ".build/kenlm-final/final.meta.json")
    parser.add_argument("--destination", type=Path, default=Path.home() / "Library/Application Support/SI/KenLM")
    args = parser.parse_args()
    print(install(args.model, args.metadata, args.destination))


if __name__ == "__main__":
    main()
