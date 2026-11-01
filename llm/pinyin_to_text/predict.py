"""Local candidate inspection; no transcript or prediction files are written."""

import argparse
import json

import torch

from .runtime import candidates, load_checkpoint, select_device


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkpoint", required=True)
    parser.add_argument("--input", required=True)
    parser.add_argument("--device", choices=("auto", "cpu", "mps", "cuda"), default="auto")
    parser.add_argument("--beam-size", type=int)
    args = parser.parse_args()
    torch.set_num_threads(4)
    device = select_device(args.device)
    checkpoint, model, tokenizer = load_checkpoint(args.checkpoint, device)
    size = args.beam_size if args.beam_size is not None else checkpoint["config"]["decoding"]["beam_size"]
    if not 1 <= size <= 32:
        parser.error("beam-size must be between 1 and 32")
    print(json.dumps(candidates(model, tokenizer, args.input, device, size,
                                checkpoint["config"]["decoding"]["length_penalty"]), ensure_ascii=False))


if __name__ == "__main__":
    main()
