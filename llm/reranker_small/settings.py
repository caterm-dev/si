"""Strict baseline configuration and code identity; no model initialization."""

import math
from pathlib import Path

from llm.pinyin_to_text.common import file_hash, fingerprint, read_json, write_json

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[1]
SPLITS = ("train", "validation", "test")


def load_config(path):
    value = read_json(path)
    if value.get("schema_version") != 1:
        raise ValueError("Unsupported reranker configuration")
    model, data, training, scoring = (value[key] for key in ("model", "data", "training", "scoring"))
    if type(value["seed"]) is not int:
        raise ValueError("Seed must be an integer")
    for key in ("vocab_size", "layers", "width", "heads", "feedforward", "context"):
        if type(model[key]) is not int or model[key] <= 0:
            raise ValueError("Positive integer required: model." + key)
    if not 260 <= model["vocab_size"] <= 65536 or model["width"] % model["heads"] or model["context"] < 2:
        raise ValueError("Invalid vocabulary, head width or context size")
    if not 0 <= model["dropout"] < 1:
        raise ValueError("Dropout must be in [0, 1)")
    if (not isinstance(data["sources"], list) or not data["sources"]
            or len(data["sources"]) != len(set(data["sources"]))):
        raise ValueError("Select distinct corpus source IDs")
    if not all(isinstance(name, str) and name for name in data["sources"]):
        raise ValueError("Corpus IDs must be nonempty strings")
    fractions = [data[key] for key in ("validation_fraction", "test_fraction")]
    if any(not math.isfinite(x) or not 0 < x < 1 for x in fractions) or sum(fractions) >= 1:
        raise ValueError("Invalid held-out document fractions")
    for key in ("max_characters_per_source", "max_document_characters", "minimum_han_characters"):
        if type(data[key]) is not int or data[key] < (0 if key == "max_characters_per_source" else 1):
            raise ValueError("Invalid data limit: " + key)
    for key in ("batch_size", "gradient_accumulation", "max_steps", "schedule_steps", "warmup_steps",
                "validate_every", "save_every", "validation_tokens"):
        if type(training[key]) is not int or training[key] <= 0:
            raise ValueError("Positive integer required: training." + key)
    if type(training["max_tokens"]) is not int or training["max_tokens"] < 0:
        raise ValueError("max_tokens must be nonnegative")
    if training["warmup_steps"] >= training["schedule_steps"]:
        raise ValueError("Warmup must be shorter than the original schedule")
    for key in ("learning_rate", "gradient_clip", "weight_decay"):
        if not math.isfinite(training[key]) or training[key] < (0 if key == "weight_decay" else 1e-20):
            raise ValueError("Invalid optimizer setting: " + key)
    if (type(scoring["batch_size"]) is not int or scoring["batch_size"] <= 0
            or type(scoring["max_candidates"]) is not int or not 1 <= scoring["max_candidates"] <= 128
            or not math.isfinite(scoring["length_penalty"]) or not 0 <= scoring["length_penalty"] <= 2):
        raise ValueError("Invalid scoring limits")
    return value


def code_identity():
    paths = [*ROOT.glob("*.py"), REPO / "llm/pinyin_to_text/tokenizer.py",
             REPO / "llm/pinyin_to_text/common.py", REPO / "llm/pinyin_to_text/runtime.py"]
    return fingerprint({str(path.relative_to(REPO)): file_hash(path) for path in sorted(paths)})


def resume_identity(config):
    value = {**config, "training": dict(config["training"])}
    for name in ("max_steps", "max_tokens"):
        value["training"].pop(name)
    return fingerprint(value)
