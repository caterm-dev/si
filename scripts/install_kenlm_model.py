#!/usr/bin/env python3
"""Verify and install or bundle a full-data KenLM model for SI."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]
MODEL_RELATIVE_DIRECTORY = Path("corpus/kenlm/models/current")
DEFAULT_MODEL_DIRECTORY = ROOT / MODEL_RELATIVE_DIRECTORY


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


def verify_model(binary, metadata):
    """Check retained inputs before a build or any attempt to stop SI."""
    _, data = compatible_metadata(metadata)
    digest = hashlib.sha256()
    with binary.open('rb') as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    if digest.hexdigest() != data['model']['binary_sha256'] or binary.stat().st_size != data['model']['binary_bytes']:
        raise ValueError('Model checksum or size does not match metadata')
    return data


def publish(binary, metadata, store=None):
    """Retain a verified trained model outside disposable build directories."""
    store = DEFAULT_MODEL_DIRECTORY.parent if store is None else store
    metadata_bytes, data = compatible_metadata(metadata)
    sha = data['model']['binary_sha256']
    if not re.fullmatch('[0-9a-f]{64}', sha) or data.get('functional_sanity_passed') is not True:
        raise ValueError('Only a sanity-validated trained model can be published')
    current = store / 'current'
    if current.exists() and not current.is_symlink():
        raise ValueError('Model store current path must be a version pointer')
    store.mkdir(parents=True, exist_ok=True, mode=0o700)
    version = store / sha
    if version.exists():
        verify_model(binary, metadata)
        retained = verify_model(version / 'final.bin', version / 'final.meta.json')
        if retained['model']['binary_sha256'] != sha:
            raise ValueError('Retained model identity differs')
    else:
        with tempfile.TemporaryDirectory(prefix='.publish-', dir=store) as work:
            payload = Path(work) / 'model'
            payload.mkdir(mode=0o700)
            copy_verified_model(binary, payload / 'final.bin', data['model'])
            (payload / 'final.meta.json').write_bytes(metadata_bytes)
            reference = metadata.parent / 'sanity/native-reference.json'
            if reference.is_file():
                if json.loads(reference.read_text())['model_sha256'] != sha:
                    raise ValueError('Native reference belongs to a different model')
                shutil.copyfile(reference, payload / 'native-reference.json')
            run = metadata.parent.parent
            for relative in ('input-code-pin.json', 'dictionary-snapshot.json', 'english-dictionary-snapshot.json',
                             'commands.jsonl', 'selection/block-audit.json', 'final/commands.jsonl',
                             'final/sanity/results.json', 'final/sanity/pairs.json'):
                source = run / relative
                if source.is_file():
                    target = payload / 'provenance' / relative
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(source, target)
            for path in payload.rglob('*'):
                path.chmod(0o700 if path.is_dir() else 0o400)
            payload.rename(version)
    pointer = store / ('.current-' + uuid.uuid4().hex)
    try:
        pointer.symlink_to(sha)
        os.replace(pointer, current)
    finally:
        pointer.unlink(missing_ok=True)
    return current


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
    mode.add_argument("--verify-only", action="store_true", help="verify model and metadata without changing anything")
    mode.add_argument("--publish", action="store_true", help="retain a trained model outside .build and select it for delivery")
    args = parser.parse_args()
    try:
        if args.verify_only:
            print('Verified KenLM: ' + verify_model(args.model, args.metadata)['model']['binary_sha256'])
        elif args.publish:
            print(publish(args.model, args.metadata))
        elif args.bundle_resources is not None:
            print(bundle(args.model, args.metadata, args.bundle_resources))
        else:
            destination = args.destination or Path.home() / "Library/Application Support/SI/KenLM"
            print(install(args.model, args.metadata, destination))
    except FileNotFoundError as error:
        parser.exit(1, f'Missing trained KenLM artifact: {error.filename}\n'
                    'An app build does not recreate the trained model. Restore a retained model, or run:\n'
                    '  corpus/.venv/bin/python scripts/retrain_kenlm.py\n')
    except (ValueError, OSError, KeyError, TypeError) as error:
        parser.exit(1, f'KenLM model error: {error}\n')


if __name__ == "__main__":
    main()
