"""Evaluate validation candidates; final test is a separate explicit command."""

import argparse
import math
import time
from pathlib import Path

import torch

from .common import file_hash, fingerprint, load_config, write_json
from .metrics import cases, summarize
from .prepare import clean_rows, normalized
from .runtime import candidates, load_bundle, load_checkpoint, select_device


def evaluate(data, split, output, checkpoint_path=None, config_path=None, baseline=None,
             device_name="auto", beam_size=None, limit=None, threads=4, benchmark_path=None):
    if split not in ("validation", "test"):
        raise ValueError("Evaluation must use validation or test")
    if threads <= 0 or (limit is not None and limit <= 0):
        raise ValueError("threads and limit must be positive")
    torch.set_num_threads(threads)
    device = select_device(device_name)
    model = None
    if checkpoint_path:
        checkpoint, model, tokenizer = load_checkpoint(checkpoint_path, device)
        config = checkpoint["config"]
        identity = {"kind": "model", "checkpoint_sha256": file_hash(checkpoint_path), "step": checkpoint["step"]}
    elif baseline == "literal":
        config = load_config(config_path)
        identity = {"kind": "literal-baseline"}
    else:
        raise ValueError("Choose a checkpoint or the literal baseline")
    manifest, bundle_tokenizer, rows = load_bundle(data, config, ("train", "validation") if benchmark_path else (split,))
    if model is not None and (checkpoint["dataset_id"] != manifest["dataset_id"] or tokenizer.digest != bundle_tokenizer.digest):
        raise ValueError("Checkpoint was trained on a different prepared dataset/tokenizer")
    k = beam_size if beam_size is not None else config["decoding"]["beam_size"]
    if not 1 <= k <= 32:
        raise ValueError("beam_size must be between 1 and 32")
    evaluation_id = manifest["dataset_id"]
    benchmark_sources = None
    if benchmark_path:
        benchmark_rows, _, benchmark_sources = clean_rows(benchmark_path)
        # Freeze an external benchmark before corpus iteration, without sharing its
        # tokenizer or labels with training. Reject exact normalized train/dev overlap.
        used_inputs = {normalized(row["input"]) for records in rows.values() for row in records}
        used_targets = {normalized(row["target"]) for records in rows.values() for row in records}
        if any(normalized(row["input"]) in used_inputs or normalized(row["target"]) in used_targets for row in benchmark_rows):
            raise ValueError("Benchmark overlaps training/validation input or target")
        evaluation_id = fingerprint({"sources": benchmark_sources, "rows": benchmark_rows})
        all_cases = cases(benchmark_rows)
    else:
        all_cases = cases(rows[split])
    if not all_cases:
        raise ValueError("Evaluation split is empty")
    selected = all_cases if limit is None else all_cases[:limit]
    observations, durations = [], []
    for case in selected:
        if device.type == "cuda":
            torch.cuda.synchronize()
        elif device.type == "mps":
            torch.mps.synchronize()
        start = time.perf_counter()
        prediction = candidates(model, tokenizer, case["input"], device, k, config["decoding"]["length_penalty"]) if model is not None else {
            "model_candidates": [case["input"]], "candidates": [case["input"]]}
        if device.type == "cuda":
            torch.cuda.synchronize()
        elif device.type == "mps":
            torch.mps.synchronize()
        durations.append((time.perf_counter() - start) * 1000)
        observations.append((case, prediction))
    ordered = sorted(durations)
    report = {
        "schema_version": 1, "dataset_id": evaluation_id, "split": split,
        "training_dataset_id": manifest["dataset_id"], "benchmark_sources": benchmark_sources,
        "evaluation_scope": fingerprint([{key: sorted(value) if isinstance(value, set) else value
                                           for key, value in case.items()} for case in selected]),
        "total_cases": len(all_cases), "evaluated_cases": len(selected), "partial": len(selected) < len(all_cases),
        "predictor": identity, "device": str(device), "torch_version": str(torch.__version__), "threads": threads,
        "metrics": summarize(observations, k),
        "timing_ms": {"p50": ordered[max(0, math.ceil(len(ordered) * .5) - 1)],
                      "p95": ordered[max(0, math.ceil(len(ordered) * .95) - 1)],
                      "note": "Serial offline decoding; includes first inference, excludes model loading. No host latency claim."},
    }
    if Path(output).exists():
        raise ValueError("Report already exists; use a new output name")
    write_json(output, report)
    return report


def main(test_only=False):
    parser = argparse.ArgumentParser(description=__doc__)
    predictor = parser.add_mutually_exclusive_group(required=True)
    predictor.add_argument("--checkpoint", type=Path)
    predictor.add_argument("--baseline", choices=("literal",))
    parser.add_argument("--config", type=Path, default=Path("llm/configs/0.4b.json"), help="Baseline config; model config is embedded in checkpoint")
    parser.add_argument("--data", type=Path, required=True)
    parser.add_argument("--benchmark", type=Path, help="Optional frozen external source manifest; audited against --data train/validation")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--device", choices=("auto", "cpu", "mps", "cuda"), default="auto")
    parser.add_argument("--beam-size", type=int)
    parser.add_argument("--limit", type=int, help="Quick partial evaluation; reports are marked partial")
    parser.add_argument("--threads", type=int, default=4)
    args = parser.parse_args()
    report = evaluate(args.data, "test" if test_only else "validation", args.output, args.checkpoint, args.config,
                      args.baseline, args.device, args.beam_size, args.limit, args.threads, args.benchmark)
    print(report["metrics"]["overall"])


if __name__ == "__main__":
    main()
