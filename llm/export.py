"""Export a local inference checkpoint without optimizer or RNG state."""

import argparse
from pathlib import Path

import torch

from .runtime import atomic_checkpoint


def export(checkpoint_path, output):
    output = Path(output)
    if output.exists():
        raise ValueError("Export already exists; choose a new output")
    checkpoint = torch.load(checkpoint_path, map_location="cpu", weights_only=True)
    if checkpoint.get("schema_version") != 1:
        raise ValueError("Unsupported checkpoint")
    keys = ("schema_version", "config", "dataset_id", "tokenizer", "tokenizer_digest", "model", "step")
    payload = {key: checkpoint[key] for key in keys}
    payload["purpose"] = "inference-only; not a resumable training checkpoint"
    output.parent.mkdir(parents=True, exist_ok=True)
    atomic_checkpoint(output, payload)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    export(args.checkpoint, args.output)
    print(f"Exported {args.output}")


if __name__ == "__main__":
    main()
