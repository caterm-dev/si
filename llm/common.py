"""Small, deterministic file/configuration helpers; no ML imports."""

import hashlib
import json
import math
import os
import tempfile
from pathlib import Path


def read_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def canonical_bytes(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")


def fingerprint(value):
    return hashlib.sha256(canonical_bytes(value)).hexdigest()


def file_hash(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent, delete=False) as stream:
        temporary = Path(stream.name)
        try:
            json.dump(value, stream, ensure_ascii=False, indent=2, allow_nan=False)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        except BaseException:
            temporary.unlink(missing_ok=True)
            raise
    os.replace(temporary, path)


def read_jsonl(path):
    with Path(path).open(encoding="utf-8") as stream:
        for number, line in enumerate(stream, 1):
            if line.strip():
                try:
                    yield json.loads(line)
                except json.JSONDecodeError as error:
                    raise ValueError(f"Invalid JSON at {path}:{number}") from error


def write_jsonl(path, rows):
    with Path(path).open("w", encoding="utf-8") as stream:
        for row in rows:
            stream.write(canonical_bytes(row).decode("utf-8") + "\n")


def load_config(path):
    config = read_json(path)
    if config.get("schema_version") != 1:
        raise ValueError("Unsupported configuration schema")
    model, data, training, decoding = (config[key] for key in ("model", "data", "training", "decoding"))
    for key in ("vocab_size", "d_model", "nhead", "encoder_layers", "decoder_layers", "dim_feedforward",
                "max_source_tokens", "max_target_tokens"):
        if type(model[key]) is not int or model[key] <= 0:
            raise ValueError(f"model.{key} must be a positive integer")
    if model["vocab_size"] < 260 or model["d_model"] % model["nhead"] or model["d_model"] % 2:
        raise ValueError("Need >=260 tokens, even width and width divisible by attention heads")
    if not 0 <= model["dropout"] < 1 or min(model["max_source_tokens"], model["max_target_tokens"]) < 3:
        raise ValueError("Invalid dropout or sequence limits")
    ratios = data["split_ratios"]
    if len(ratios) != 3 or any(r <= 0 for r in ratios) or not math.isclose(sum(ratios), 1):
        raise ValueError("Three positive train/validation/test ratios must sum to one")
    if type(config["seed"]) is not int:
        raise ValueError("seed must be an integer")
    for key in ("noise_variants", "max_edits"):
        if type(data[key]) is not int or data[key] < 0:
            raise ValueError(f"data.{key} must be a nonnegative integer")
    for key in ("batch_size", "gradient_accumulation", "max_steps", "schedule_steps", "warmup_steps",
                "validate_every", "save_every"):
        if type(training[key]) is not int or training[key] <= 0:
            raise ValueError(f"training.{key} must be a positive integer")
    if training["warmup_steps"] >= training["schedule_steps"]:
        raise ValueError("Warmup must end before schedule_steps")
    if training["precision"] not in ("fp32", "bf16"):
        raise ValueError("precision must be fp32 or bf16 (CUDA only)")
    for key in ("learning_rate", "gradient_clip", "weight_decay"):
        if not math.isfinite(training[key]) or training[key] < 0 or (key != "weight_decay" and training[key] == 0):
            raise ValueError(f"Invalid training.{key}")
    if type(training["activation_checkpointing"]) is not bool:
        raise ValueError("activation_checkpointing must be Boolean")
    if type(decoding["beam_size"]) is not int or not 1 <= decoding["beam_size"] <= 32:
        raise ValueError("beam_size must be between 1 and 32")
    if not 0 <= decoding["length_penalty"] <= 2:
        raise ValueError("Invalid length_penalty")
    return config


def verified_rows(bundle, split):
    bundle = Path(bundle)
    manifest = read_json(bundle / "manifest.json")
    name = f"{split}.jsonl"
    if file_hash(bundle / name) != manifest["files"][name]:
        raise ValueError(f"Prepared {name} was modified; prepare a new dataset")
    return list(read_jsonl(bundle / name))
