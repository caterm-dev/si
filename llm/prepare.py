"""Validate synthetic seeds and export MLX chat JSONL without model downloads."""

import argparse
import hashlib
import json
from pathlib import Path

from protocol import ROOT, Request, compact, read_jsonl, validate_candidates

SPLITS = ("train", "valid", "test")


def build(source):
    output = {split: [] for split in SPLITS}
    groups = {}
    requests = {}
    ids = set()
    for seed in read_jsonl(source):
        if set(seed) != {"id", "group", "split", "category", "request", "variants", "candidates"}:
            raise ValueError("seed has unexpected or missing fields")
        if any(not isinstance(seed[key], str) or not seed[key] for key in ("id", "group", "category")):
            raise ValueError("seed metadata must contain nonempty strings")
        if seed["id"] in ids or seed["split"] not in SPLITS:
            raise ValueError("duplicate seed ID or invalid split")
        ids.add(seed["id"])
        split = seed["split"]
        if seed["group"] in groups and groups[seed["group"]] != split:
            raise ValueError("a semantic group crosses dataset splits")
        groups[seed["group"]] = split
        base = Request.from_dict(seed["request"])
        variants = seed["variants"]
        if not isinstance(variants, list) or any(not isinstance(value, str) for value in variants):
            raise ValueError("variants must be a list of authored input strings")
        if len(set([base.input, *variants])) != 1 + len(variants):
            raise ValueError("duplicate input variant")
        for index, spelling in enumerate([base.input, *variants]):
            request = Request.from_dict({**base.as_dict(), "input": spelling})
            validate_candidates({"candidates": seed["candidates"]}, request)
            key = compact(request.as_dict())
            if key in requests:
                raise ValueError("duplicate request, possibly leaking across splits")
            requests[key] = split
            output[split].append({
                "id": f"{seed['id']}:{index}", "group": seed["group"],
                "category": seed["category"], "request": request.as_dict(),
                "expected": seed["candidates"],
            })
    if any(not rows for rows in output.values()):
        raise ValueError("train, valid and test must all contain examples")
    return output


def export(source, destination, check=False):
    dataset = build(source)
    files = {}
    for split, rows in dataset.items():
        chat = []
        for row in rows:
            messages = Request.from_dict(row["request"]).messages()
            messages.append({"role": "assistant", "content": compact({"candidates": row["expected"]})})
            chat.append({"messages": messages})
        files[f"{split}.jsonl"] = "".join(compact(row) + "\n" for row in chat)
        files[f"{split}.cases.jsonl"] = "".join(compact(row) + "\n" for row in rows)
    manifest = {
        "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
        "counts": {split: len(rows) for split, rows in dataset.items()},
        "files": {name: hashlib.sha256(content.encode()).hexdigest() for name, content in files.items()},
        "purpose": "Synthetic development data; not an independent quality benchmark or production corpus.",
    }
    files["manifest.json"] = json.dumps(manifest, indent=2) + "\n"
    if check:
        if any(not (destination / name).is_file() or (destination / name).read_text(encoding="utf-8") != content
               for name, content in files.items()):
            raise ValueError("prepared data is absent or stale; run prepare.py")
    else:
        destination.mkdir(parents=True, exist_ok=True)
        for name, content in files.items():
            (destination / name).write_text(content, encoding="utf-8")
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=ROOT / "data/seeds.jsonl")
    parser.add_argument("--output", type=Path, default=ROOT / "data/prepared")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    try:
        manifest = export(args.source, args.output, args.check)
    except (OSError, ValueError, TypeError) as error:
        parser.exit(1, f"Dataset preparation failed: {error}\n")
    print(json.dumps(manifest["counts"], sort_keys=True))


if __name__ == "__main__":
    main()
