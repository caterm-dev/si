from pathlib import Path
import csv

from llm.common import read_json, write_json

ROOT = Path(__file__).resolve().parents[1]


def collection(directory):
    root = Path(directory) / "csv"
    for split in ("train", "validation", "test"):
        (root / split).mkdir(parents=True)
    write_json(root / "provenance.json", {"schema_version": 1, "default": {
        "license": "GPL-3.0-only", "origin": "SI-authored synthetic CSV regression", "revision": "1"}, "files": {}})
    write_csv(root / "train/city.csv", [("beijing", "北京"), ("shanghai", "上海")])
    write_csv(root / "validation/city.csv", [("hangzhou", "杭州")])
    write_csv(root / "test/city.csv", [("chengdu", "成都"), ("wuhan", "武汉"), ("suzhou", "苏州")])
    return root


def write_csv(path, rows, language=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as stream:
        writer = csv.writer(stream, lineterminator="\n")
        writer.writerow(["input", "target", "language"] if language else ["input", "target"])
        writer.writerows(rows)


def tiny_config(directory, **training):
    config = read_json(ROOT / "configs/smoke.json")
    config["training"].update(training)
    path = Path(directory) / "config.json"
    write_json(path, config)
    return path
