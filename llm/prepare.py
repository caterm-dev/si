"""Validate sources, split clean groups, then augment and fit a train-only tokenizer."""

import argparse
import os
import shutil
import tempfile
import unicodedata
from collections import Counter
from pathlib import Path

from .common import file_hash, fingerprint, load_config, read_json, write_json, write_jsonl
from .noise import variants
from .sources import load_sources
from .tokenizer import Tokenizer

SPLITS = ("train", "validation", "test")


def normalized(text):
    # Only split grouping uses normalization; model input/output bytes stay intact.
    return unicodedata.normalize("NFKC", text).casefold().strip()


def text_input(target, language):
    if language == "en":
        return target
    try:
        from pypinyin import lazy_pinyin
    except ImportError as error:
        raise ValueError("Text-only Chinese sources require pypinyin; install llm/requirements.txt") from error
    return "".join(lazy_pinyin(target)).replace("ü", "v")


def clean_rows(manifest):
    rows = {}
    groups = []
    provenance = []
    for source, records in load_sources(manifest):
        provenance.append(source)
        for record in records:
            language, target = record.get("language"), record.get("target")
            if language not in ("zh", "en", "mixed") or not isinstance(target, str) or not target.strip():
                raise ValueError(f"Invalid language/target in source {source['id']}")
            if source["format"] == "text":
                if language == "mixed":
                    raise ValueError("Mixed text requires an explicit input/target pair")
                spelling = text_input(target, language)
            else:
                spelling = record.get("input")
            if not isinstance(spelling, str) or not spelling.strip():
                raise ValueError(f"Invalid input in source {source['id']}")
            if max(len(spelling.encode("utf-8")), len(target.encode("utf-8"))) > 4096:
                raise ValueError("A record exceeds the 4096-byte safety bound; segment the source explicitly")
            if any(unicodedata.category(c) in ("Cc", "Cs") for c in spelling + target):
                raise ValueError("Records must not contain control characters or surrogate scalars")
            group = record.get("group_id")
            if group is not None and (not isinstance(group, str) or not group.strip()):
                raise ValueError("group_id must be a nonempty string")
            noise = record.get("noise", "clean")
            if noise not in ("clean", "real", "delete", "insert", "substitute", "transpose"):
                raise ValueError("Unsupported imported noise label")
            key = (spelling, target, language)
            if key not in rows:
                rows[key] = {"input": spelling, "target": target, "language": language,
                             "noise": noise, "sources": []}
            elif rows[key]["noise"] != noise:
                raise ValueError("Duplicate pairs have conflicting noise labels")
            rows[key]["sources"].append(source["id"])
            # Keep ALL duplicate-group memberships; identical rows can bridge documents/sources.
            groups.append((key, f"{source['id']}:{group}" if group is not None else None))
    if not rows:
        raise ValueError("No usable records")
    ordered = sorted(rows)
    for row in rows.values():
        row["sources"] = sorted(set(row["sources"]))
    return [rows[key] for key in ordered], groups, provenance


def split_rows(rows, memberships, seed, ratios):
    parent = list(range(len(rows)))

    def root(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    def union(a, b):
        a, b = root(a), root(b)
        parent[max(a, b)] = min(a, b)

    owners = {}
    indices = {(r["input"], r["target"], r["language"]): i for i, r in enumerate(rows)}
    keys = [(i, ("input", normalized(row["input"]))) for i, row in enumerate(rows)]
    keys += [(i, ("target", normalized(row["target"]))) for i, row in enumerate(rows)]
    keys += [(indices[key], ("group", group)) for key, group in memberships if group is not None]
    for i, key in keys:
        if key in owners:
            union(i, owners[key])
        else:
            owners[key] = i
    components = {}
    for i, row in enumerate(rows):
        components.setdefault(root(i), []).append(row)
    result = {name: [] for name in SPLITS}
    for group_rows in components.values():
        group_id = fingerprint(sorted((normalized(r["input"]), normalized(r["target"])) for r in group_rows))
        fraction = int(fingerprint([seed, group_id])[:16], 16) / 2**64
        name = "train" if fraction < ratios[0] else "validation" if fraction < sum(ratios[:2]) else "test"
        result[name].extend({**row, "group": group_id} for row in group_rows)
    if any(not rows for rows in result.values()):
        raise ValueError("A split is empty; add more independent source groups or change split ratios/seed")
    return result


def prepare(config_path, sources_path, output):
    config = load_config(config_path)
    output = Path(output)
    if output.exists():
        raise ValueError("Dataset output already exists; use a new versioned directory")
    rows, memberships, provenance = clean_rows(sources_path)
    splits = split_rows(rows, memberships, config["seed"], config["data"]["split_ratios"])
    # Resolve synthetic collisions globally. Ambiguous clean rows stay in the same split.
    owners = {normalized(row["input"]): name for name, rows in splits.items() for row in rows}
    skipped_collisions = 0
    for name in SPLITS:
        clean = splits[name][:]
        for row in clean:
            if not config["data"]["noise_variants"] or row["noise"] != "clean":
                continue
            for variant in variants(row, config["seed"], config["data"]["noise_variants"], config["data"]["max_edits"]):
                key = normalized(variant["input"])
                if key in owners and owners[key] != name:
                    skipped_collisions += 1
                    continue
                owners[key] = name
                splits[name].append(variant)
        splits[name].sort(key=lambda row: fingerprint(row))
    tokenizer = Tokenizer.fit(splits["train"], config["model"]["vocab_size"])
    # Never silently truncate labels or drop difficult test samples.
    for name, records in splits.items():
        for row in records:
            if len(tokenizer.encode(row["input"])) > config["model"]["max_source_tokens"]:
                raise ValueError(f"{name} input exceeds max_source_tokens; segment data or raise the limit")
            if len(tokenizer.encode(row["target"])) > config["model"]["max_target_tokens"]:
                raise ValueError(f"{name} target exceeds max_target_tokens; segment data or raise the limit")
    output.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=".prepare-", dir=output.parent))
    try:
        tokenizer.save(staging / "tokenizer.json")
        for name, records in splits.items():
            write_jsonl(staging / f"{name}.jsonl", records)
        manifest = {
            "schema_version": 1, "sources": provenance, "seed": config["seed"],
            "data_config": config["data"], "model_limits": {key: config["model"][key] for key in
                ("vocab_size", "max_source_tokens", "max_target_tokens")},
            "tokenizer_sha256": tokenizer.digest,
            "files": {p.name: file_hash(p) for p in sorted(staging.iterdir())},
            "counts": {name: dict(Counter(row["language"] for row in records)) for name, records in splits.items()},
            "noise_counts": {name: dict(Counter(row["noise"] for row in records)) for name, records in splits.items()},
            "skipped_cross_split_noise_collisions": skipped_collisions,
        }
        manifest["dataset_id"] = fingerprint(manifest)
        write_json(staging / "manifest.json", manifest)
        os.rename(staging, output)
    finally:
        if staging.exists():
            shutil.rmtree(staging)
    return read_json(output / "manifest.json")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=Path("llm/configs/0.4b.json"))
    parser.add_argument("--sources", type=Path, default=Path("llm/configs/sources.json"))
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    manifest = prepare(args.config, args.sources, args.output)
    print({"dataset_id": manifest["dataset_id"], "counts": manifest["counts"]})


if __name__ == "__main__":
    main()
