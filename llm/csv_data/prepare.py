"""Freeze explicitly split CSV files into a versioned training bundle."""

import argparse
import csv
import hashlib
import io
import shutil
import tempfile
import unicodedata
from collections import Counter
from pathlib import Path

from ..common import file_hash, fingerprint, load_config, normalized, read_json, write_json, write_jsonl
from ..tokenizer import Tokenizer

ROOT = Path(__file__).resolve().parents[1]
SPLITS = ("train", "validation", "test")


def source_files(root, splits=SPLITS):
    """Discover every category without requiring one manifest entry per file."""
    root = Path(root)
    for child in root.iterdir():
        if child.name.startswith("."):
            continue
        if child.is_dir() and child.name not in SPLITS:
            raise ValueError(f"Unexpected split directory: {child.name}; use train, validation or test")
        if child.is_file() and child.suffix.lower() == ".csv":
            raise ValueError("Put CSV files inside train/, validation/ or test/")
    paths = []
    for split in splits:
        folder = root / split
        if not folder.is_dir():
            raise ValueError(f"Missing {split}/ directory in CSV source root")
        for path in folder.rglob("*"):
            relative = path.relative_to(root)
            if any(part.startswith(".") for part in relative.parts):
                continue
            if path.suffix.lower() == ".csv":
                if path.is_symlink() or any((root / parent).is_symlink() for parent in relative.parents if parent != Path(".")):
                    raise ValueError(f"CSV sources must be ordinary files: {relative}")
                if path.is_file():
                    paths.append(path)
    return sorted(paths, key=lambda p: p.relative_to(root).as_posix())


def provenance_for(declarations, relative):
    result = {**declarations.get("default", {}), **declarations.get("files", {}).get(relative, {})}
    for field in ("license", "origin", "revision"):
        if not isinstance(result.get(field), str) or not result[field].strip():
            raise ValueError(f"Source {relative} needs declared {field} in provenance.json")
    return {key: result[key] for key in ("license", "origin", "revision")}


def csv_records(data, relative):
    try:
        # UTF-8 BOM is accepted for CSVs saved by spreadsheet editors.
        text = data.decode("utf-8-sig")
        reader = csv.DictReader(io.StringIO(text, newline=""), strict=True)
        fields = reader.fieldnames
        if not fields or len(set(fields)) != len(fields) or set(fields) not in (
                {"input", "target"}, {"input", "target", "language"}):
            raise ValueError(f"{relative}: CSV header must be input,target with optional language")
        for row in reader:
            where = f"{relative}:{reader.line_num}"
            if None in row or any(value is None for value in row.values()):
                raise ValueError(f"{where}: column count differs from the header")
            language = row.get("language", "zh")
            if language not in ("zh", "en", "mixed"):
                raise ValueError(f"{where}: language must be zh, en or mixed")
            for field in ("input", "target"):
                value = row[field]
                if not value.strip():
                    raise ValueError(f"{where}: {field} must not be empty")
                if len(value.encode("utf-8")) > 4096:
                    raise ValueError(f"{where}: {field} exceeds 4096 UTF-8 bytes")
                if any(unicodedata.category(c) in ("Cc", "Cs") for c in value):
                    raise ValueError(f"{where}: {field} contains control characters")
            yield row["input"], row["target"], language, where
    except (UnicodeDecodeError, csv.Error) as error:
        raise ValueError(f"{relative}: invalid UTF-8 CSV") from error


def read_collection(root, splits=SPLITS):
    root = Path(root)
    if not splits or any(split not in SPLITS for split in splits):
        raise ValueError("Select train, validation or test CSV directories")
    declarations = read_json(root / "provenance.json")
    if declarations.get("schema_version") != 1:
        raise ValueError("Unsupported CSV provenance schema")
    paths = source_files(root, splits)
    relatives = {p.relative_to(root).as_posix() for p in paths}
    if {name for name in declarations.get("files", {}) if Path(name).parts[0] in splits} - relatives:
        raise ValueError("provenance.json contains file overrides for missing CSVs")
    rows = {split: {} for split in splits}
    owners = {"input": {}, "target": {}}
    sources, snapshots, counts = [], {}, {}
    for path in paths:
        relative = path.relative_to(root)
        name = relative.as_posix()
        split = relative.parts[0]
        group = Path(*relative.parts[1:]).with_suffix("").as_posix()
        source_id = relative.with_suffix("").as_posix()
        data = path.read_bytes()
        snapshots["source_csv/" + name] = data
        # Hash exactly the bytes parsed, not a later reopening of an editable CSV.
        source = {"id": source_id, "path": name, "snapshot": "source_csv/" + name,
                  "sha256": hashlib.sha256(data).hexdigest(), "format": "csv", "split": split,
                  "group": group, **provenance_for(declarations, name)}
        count = 0
        for spelling, target, language, where in csv_records(data, name):
            for field, value in (("input", spelling), ("target", target)):
                key = normalized(value)
                if key in owners[field] and owners[field][key][0] != split:
                    raise ValueError(f"Cross-split {field} overlap: {owners[field][key][1]} and {where}; move related rows into one split")
                owners[field].setdefault(key, (split, where))
            key = (spelling, target, language)
            if key not in rows[split]:
                rows[split][key] = {"input": spelling, "target": target, "language": language,
                                    "noise": "clean" if spelling == target else "provided",
                                    "sources": [], "groups": []}
            record = rows[split][key]
            record["sources"].append(source_id)
            record["groups"].append(group)
            count += 1
        source["rows"] = count
        sources.append(source)
        counts[name] = count
    result = {}
    for split, records in rows.items():
        if not records:
            raise ValueError(f"{split}/ must contain at least one nonempty CSV")
        result[split] = []
        for key in sorted(records):
            record = records[key]
            record["sources"] = sorted(set(record["sources"]))
            record["groups"] = sorted(set(record["groups"]))
            result[split].append(record)
    return result, sources, snapshots, counts, declarations


def prepare(config_path, csv_root, output):
    config = load_config(config_path)
    output = Path(output)
    if output.exists():
        raise ValueError("Dataset output already exists; use a new versioned directory")
    splits, sources, snapshots, counts, declarations = read_collection(csv_root)
    tokenizer = Tokenizer.fit(splits["train"], config["model"]["vocab_size"])
    for split, records in splits.items():
        for row in records:
            for field, limit in (("input", "max_source_tokens"), ("target", "max_target_tokens")):
                if len(tokenizer.encode(row[field])) > config["model"][limit]:
                    raise ValueError(f"{split}: {field} exceeds {limit}; fix the CSV or raise the limit")
    output.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=".csv-prepare-", dir=output.parent))
    try:
        for relative, data in snapshots.items():
            path = staging / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        write_json(staging / "source_csv/provenance.json", declarations)
        for split, records in splits.items():
            write_jsonl(staging / f"{split}.jsonl", records)
        tokenizer.save(staging / "tokenizer.json")
        manifest = {
            "schema_version": 1, "sources": sources, "seed": config["seed"],
            "data_config": {"format": "static-csv", "split_policy": "directory", "augmentation": "none"},
            "model_limits": {key: config["model"][key] for key in
                             ("vocab_size", "max_source_tokens", "max_target_tokens")},
            "tokenizer_sha256": tokenizer.digest,
            "files": {p.relative_to(staging).as_posix(): file_hash(p) for p in sorted(staging.rglob("*")) if p.is_file()},
            "counts": {split: dict(Counter(r["language"] for r in records)) for split, records in splits.items()},
            "noise_counts": {split: dict(Counter(r["noise"] for r in records)) for split, records in splits.items()},
            "source_counts": counts,
        }
        manifest["dataset_id"] = fingerprint(manifest)
        write_json(staging / "manifest.json", manifest)
        staging.rename(output)
    finally:
        if staging.exists():
            shutil.rmtree(staging)
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=ROOT / "configs/0.4b-static-csv.json")
    parser.add_argument("--csv-root", type=Path, default=ROOT / "data/csv")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    manifest = prepare(args.config, args.csv_root, args.output)
    print({"dataset_id": manifest["dataset_id"], "counts": manifest["counts"], "files": len(manifest["sources"])})


if __name__ == "__main__":
    main()
