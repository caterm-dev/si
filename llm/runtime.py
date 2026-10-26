"""Shared local checkpoint loading, tensor batches and bounded candidate decoding."""

import os
import random
import tempfile
import unicodedata
from pathlib import Path

import torch
from torch.nn.utils.rnn import pad_sequence

from .common import file_hash, fingerprint, read_json, verified_rows
from .model import SpellingTransformer
from .tokenizer import BOS, EOS, PAD, Tokenizer


def select_device(name):
    if name == "auto":
        name = "cuda" if torch.cuda.is_available() else "mps" if torch.backends.mps.is_available() else "cpu"
    if name == "cuda" and not torch.cuda.is_available():
        raise ValueError("CUDA is unavailable")
    if name == "mps" and not torch.backends.mps.is_available():
        raise ValueError("MPS is unavailable")
    return torch.device(name)


def seed_everything(seed):
    os.environ.setdefault("CUBLAS_WORKSPACE_CONFIG", ":4096:8")
    random.seed(seed)
    torch.manual_seed(seed)
    torch.use_deterministic_algorithms(True)


def load_bundle(path, config, splits):
    path = Path(path)
    manifest = read_json(path / "manifest.json")
    identity = {key: value for key, value in manifest.items() if key != "dataset_id"}
    if fingerprint(identity) != manifest["dataset_id"]:
        raise ValueError("Dataset manifest identity mismatch")
    if file_hash(path / "tokenizer.json") != manifest["files"]["tokenizer.json"]:
        raise ValueError("Tokenizer file checksum mismatch")
    tokenizer = Tokenizer.load(path / "tokenizer.json")
    if tokenizer.digest != manifest["tokenizer_sha256"]:
        raise ValueError("Tokenizer identity mismatch")
    limits = {key: config["model"][key] for key in ("vocab_size", "max_source_tokens", "max_target_tokens")}
    if limits != manifest["model_limits"]:
        raise ValueError("Dataset/tokenizer limits differ from model; prepare a matching dataset")
    rows = {split: verified_rows(path, split) for split in splits}
    return manifest, tokenizer, rows


def tensors(rows, tokenizer, config):
    result = []
    for row in rows:
        source, target = tokenizer.encode(row["input"]), tokenizer.encode(row["target"])
        if len(source) > config["max_source_tokens"] or len(target) > config["max_target_tokens"]:
            raise ValueError("Oversized record; truncation is not allowed")
        result.append((torch.tensor(source, dtype=torch.long), torch.tensor(target, dtype=torch.long)))
    return result


def collate(batch, device):
    source = pad_sequence([row[0] for row in batch], batch_first=True, padding_value=PAD).to(device)
    target = pad_sequence([row[1] for row in batch], batch_first=True, padding_value=PAD).to(device)
    return source, target[:, :-1], target[:, 1:]


def atomic_checkpoint(path, payload):
    path = Path(path)
    fd, temporary = tempfile.mkstemp(prefix=".checkpoint-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            torch.save(payload, stream)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def load_checkpoint(path, device):
    # Save only state_dicts and primitive metadata; never deserialize arbitrary modules.
    checkpoint = torch.load(path, map_location="cpu", weights_only=True)
    if checkpoint.get("schema_version") != 1:
        raise ValueError("Unsupported checkpoint")
    config = checkpoint["config"]
    tokenizer = Tokenizer(checkpoint["tokenizer"]["vocab_size"], checkpoint["tokenizer"]["characters"])
    if tokenizer.digest != checkpoint["tokenizer_digest"]:
        raise ValueError("Checkpoint tokenizer identity mismatch")
    model = SpellingTransformer(config["model"], tokenizer.active_ids,
                                config["training"]["activation_checkpointing"])
    model.load_state_dict(checkpoint["model"])
    model.to(device).eval()
    return checkpoint, model, tokenizer


@torch.inference_mode()
def candidates(model, tokenizer, spelling, device, beam_size, length_penalty):
    if not spelling:
        return {"model_candidates": [], "candidates": []}
    source_ids = tokenizer.encode(spelling)
    if len(source_ids) > model.config["max_source_tokens"]:
        return {"model_candidates": [], "candidates": [spelling]}
    source = torch.tensor([source_ids], dtype=torch.long, device=device)
    memory, padding = model.encode(source)
    beams = [([BOS], 0.0)]

    def score(beam):
        return beam[1] / max(1, len(beam[0]) - 1) ** length_penalty

    for _ in range(model.config["max_target_tokens"] - 1):
        proposals = []
        for tokens, log_probability in beams:
            if tokens[-1] == EOS:
                proposals.append((tokens, log_probability))
                continue
            target = torch.tensor([tokens], dtype=torch.long, device=device)
            logits = model.decode(target, memory, padding)[0, -1].float().log_softmax(-1)
            # Stable sorting preserves deterministic token-ID tie order.
            indices = torch.argsort(logits, descending=True, stable=True)[:beam_size].tolist()
            proposals.extend(([*tokens, token], log_probability + float(logits[token])) for token in indices)
        beams = sorted(proposals, key=lambda beam: (-score(beam), beam[0]))[:beam_size]
        if all(tokens[-1] == EOS for tokens, _ in beams):
            break
    outputs = []
    for tokens, _ in sorted(beams, key=lambda beam: (-score(beam), beam[0])):
        # Incomplete/invalid UTF-8 or control output never becomes a commit candidate.
        if tokens[-1] != EOS:
            continue
        try:
            text = tokenizer.decode(tokens)
        except (UnicodeDecodeError, ValueError):
            continue
        if text and text not in outputs and not any(unicodedata.category(c) in ("Cc", "Cs") for c in text):
            outputs.append(text)
    return {"model_candidates": outputs, "candidates": outputs if spelling in outputs else [*outputs, spelling]}
