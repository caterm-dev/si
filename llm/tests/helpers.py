from pathlib import Path

from llm.common import file_hash, read_json, write_json, write_jsonl

ROOT = Path(__file__).resolve().parents[1]


def manifest_for(directory, records, format="pairs"):
    directory = Path(directory)
    write_jsonl(directory / "pairs.jsonl", records)
    path = directory / "sources.json"
    write_json(path, {"schema_version": 1, "sources": [{
        "id": "synthetic", "path": "pairs.jsonl", "format": format,
        "sha256": file_hash(directory / "pairs.jsonl"), "license": "GPL-3.0-only",
        "origin": "SI-authored synthetic test", "revision": "1",
    }]})
    return path


def tiny_config(directory, **training):
    config = read_json(ROOT / "configs/smoke.json")
    config["training"].update(training)
    path = Path(directory) / "config.json"
    write_json(path, config)
    return path
