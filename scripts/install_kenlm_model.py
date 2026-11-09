#!/usr/bin/env python3
"""Verify and install or bundle a full-data KenLM model for SI."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MODEL_DIRECTORY = ROOT / ".build/kenlm-raw-text-v2-no-wikipedia-p0012/final"


def stamp(path):
    state = path.stat()
    seconds, nanos = divmod(state.st_mtime_ns, 10**9)
    return {"bytes": state.st_size, "mtime_seconds": seconds, "mtime_nanos": nanos}


def compatible_metadata(metadata):
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
            or model["order"] != 4 or model["a"] != 22 or model["prune"] not in ([0, 0, 1, 2], [0, 1, 2, 3])
            or model["probability_bits"] != 8 or model["backoff_bits"] != 8):
        raise ValueError("Incompatible full-data model metadata")
    return metadata_bytes, data


def copy_verified_model(binary, target, model):
    digest = hashlib.sha256()
    with binary.open("rb") as source, target.open("wb") as output:
        while chunk := source.read(1024 * 1024):
            output.write(chunk)
            digest.update(chunk)
    sha = digest.hexdigest()
    if sha != model["binary_sha256"] or target.stat().st_size != model["binary_bytes"]:
        raise ValueError("Model checksum or size does not match metadata")
    return sha


def install(binary, metadata, destination):
    metadata_bytes, data = compatible_metadata(metadata)
    destination.mkdir(parents=True, exist_ok=True, mode=0o700)
    with tempfile.TemporaryDirectory(prefix=".install-", dir=destination) as work:
        stage = Path(work)
        payload = stage / "payload"
        payload.mkdir(mode=0o700)
        target = payload / "final.bin"
        sha = copy_verified_model(binary, target, data["model"])
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


def bundle(binary, metadata, resources):
    _, data = compatible_metadata(metadata)
    destination = resources / "KenLM"
    if destination.exists() or destination.is_symlink():
        raise FileExistsError(f"KenLM resources already exist: {destination}")
    with tempfile.TemporaryDirectory(prefix=".kenlm-", dir=resources) as work:
        payload = Path(work) / "KenLM"
        payload.mkdir()
        copy_verified_model(binary, payload / "final.bin", data["model"])
        # The training record contains local paths and command logs. Ship only
        # compatibility metadata, without relying on timestamps surviving packaging.
        model_fields = ("binary_sha256", "binary_bytes", "order", "a", "prune", "probability_bits", "backoff_bits")
        compatibility = {"schema_version": data["schema_version"], "cleaning": data["cleaning"],
                         "kenlm": {"binary_format_version": data["kenlm"]["binary_format_version"]},
                         "model": {field: data["model"][field] for field in model_fields}}
        (payload / "final.meta.json").write_text(json.dumps(compatibility, indent=2) + "\n", encoding="utf-8")
        shutil.copytree(ROOT / "Vendor/SIKenLM/Notices", payload / "KenLM-Notices")
        corpus = ROOT / "corpus/chinese"
        shutil.copytree(corpus / "licenses", payload / "Corpus-Notices/licenses")
        shutil.copyfile(corpus / "sources.lock.json", payload / "Corpus-Notices/sources.lock.json")
        sources = data.get("sources", {}).get("sources", [])
        if sources:
            selection = {"sources": [row["source"] for row in sources],
                         "excluded_sources": data["sources"].get("excluded_sources", [])}
            (payload / "Corpus-Notices/training-sources.json").write_text(
                json.dumps(selection, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            for row in sources:
                if row["id"] != "dialogue":
                    continue
                prepared = (ROOT / row["raw_text_directory"]).resolve()
                if (not prepared.is_relative_to((corpus / "prepared").resolve())
                        or hashlib.sha256((prepared / "manifest.json").read_bytes()).hexdigest()
                        != row["identity"]["raw_text_manifest_sha256"]):
                    raise ValueError("Dialogue attribution does not match model provenance")
                extraction = json.loads((prepared / "manifest.json").read_bytes())
                for name, expected in extraction["files"].items():
                    if name.startswith("attribution/"):
                        if hashlib.sha256((prepared / name).read_bytes()).hexdigest() != expected["sha256"]:
                            raise ValueError("Dialogue attribution checksum mismatch")
                shutil.copytree(prepared / "attribution", payload / "Corpus-Notices/dialogue")
        payload.rename(destination)
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", type=Path, default=DEFAULT_MODEL_DIRECTORY / "final.bin")
    parser.add_argument("--metadata", type=Path, default=DEFAULT_MODEL_DIRECTORY / "final.meta.json")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--destination", type=Path)
    mode.add_argument("--bundle-resources", type=Path, help="stage the verified model inside an unsigned app's Resources")
    args = parser.parse_args()
    if args.bundle_resources is not None:
        print(bundle(args.model, args.metadata, args.bundle_resources))
    else:
        destination = args.destination or Path.home() / "Library/Application Support/SI/KenLM"
        print(install(args.model, args.metadata, destination))


if __name__ == "__main__":
    main()
