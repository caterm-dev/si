"""Offline Qwen3.5 input-method training, candidate generation and evaluation."""

import argparse
import json
import math
import sys
from pathlib import Path
from types import SimpleNamespace

from prepare import export
from protocol import ROOT, Request, compact, identity, read_jsonl
from runtime import Generator, NonThinkingTokenizer, check_platform, doctor, model_directory, offline_environment


def score_case(case, result):
    # Only model suggestions count. The always-added literal must not inflate quality.
    rows = [row for row in result["candidates"] if row["language"] != "verbatim"]
    expected = case["expected"]
    acceptable = {identity(row) for row in expected}
    request = Request.from_dict(case["request"])
    if not expected:
        hit_one = hit_five = not rows and result["status"] != "invalid_response"
        reciprocal = float(hit_one)
    else:
        ranks = [index + 1 for index, row in enumerate(rows) if identity(row) in acceptable]
        hit_one, hit_five = bool(ranks and ranks[0] == 1), bool(ranks and ranks[0] <= 5)
        reciprocal = 1 / ranks[0] if ranks else 0.0
    preserve = case["category"] == "preserve"
    return {
        "top1": int(hit_one), "top5": int(hit_five), "reciprocal_rank": reciprocal,
        "invalid": int(result["status"] == "invalid_response"),
        "bypassed": int(result["status"] == "bypassed"),
        "preserve_cases": int(preserve), "preserve_top1_errors": int(preserve and not hit_one),
        "literal_ok": int(request.task != "convert" or not request.input or any(
            row == {"text": request.input, "language": "verbatim"} for row in result["candidates"]
        )),
        "total_ms": result["timing"]["total_ms"],
        "first_token_ms": result["timing"]["first_token_ms"],
    }


def percentile(values, fraction):
    values = sorted(values)
    return values[max(0, math.ceil(len(values) * fraction) - 1)] if values else None


def summarize(scores):
    count = len(scores)
    if not count:
        return {"cases": 0}
    timed = [row for row in scores if not row["bypassed"]]
    preserve = sum(row["preserve_cases"] for row in scores)
    return {
        "cases": count,
        "top1_acceptable_rate": sum(row["top1"] for row in scores) / count,
        "top5_acceptable_rate": sum(row["top5"] for row in scores) / count,
        "mean_reciprocal_rank": sum(row["reciprocal_rank"] for row in scores) / count,
        "invalid_responses": sum(row["invalid"] for row in scores),
        "bypassed_requests": sum(row["bypassed"] for row in scores),
        "literal_failures": sum(not row["literal_ok"] for row in scores),
        "preserve_cases": preserve,
        "preserve_top1_error_rate": sum(row["preserve_top1_errors"] for row in scores) / preserve if preserve else None,
        "generated_requests": len(timed),
        "total_ms_p50": percentile([row["total_ms"] for row in timed], 0.50),
        "total_ms_p95": percentile([row["total_ms"] for row in timed], 0.95),
        "first_token_ms_p95": percentile([row["first_token_ms"] for row in timed if row["first_token_ms"] is not None], 0.95),
    }


def validate_training_steps(config):
    accumulation = config.get("grad_accumulation_steps", 1)
    iterations = config.get("iters", 0)
    if type(accumulation) is not int or type(iterations) is not int or accumulation < 1 or iterations < 1:
        raise ValueError("Iterations and gradient accumulation must be positive integers")
    if iterations % accumulation:
        raise ValueError("Iterations must be a multiple of gradient accumulation so every gradient is applied")


def train(args):
    check_platform()
    offline_environment()
    model_path = model_directory(args.model)
    output = args.output.expanduser().resolve()
    if output.exists():
        raise ValueError("Training requires a new --output directory; existing runs are never overwritten")
    # Validate source/split isolation and prepared hashes before any GPU work.
    manifest = export(args.source, args.data, check=True)
    import yaml

    config = yaml.safe_load(args.config.read_text())
    allowed = {
        "fine_tune_type", "num_layers", "batch_size", "grad_accumulation_steps", "iters",
        "learning_rate", "max_seq_length", "grad_checkpoint", "mask_prompt", "val_batches",
        "steps_per_report", "steps_per_eval", "save_every", "seed", "report_to", "lora_parameters",
    }
    if not isinstance(config, dict) or set(config) - allowed or config.get("report_to") is not None:
        raise ValueError("Unsupported training configuration; remote reporting is disabled")
    if config.get("fine_tune_type") != "lora" or config.get("mask_prompt") is not True:
        raise ValueError("This experiment uses LoRA/QLoRA with assistant-only loss")
    if args.iters is not None:
        config["iters"] = args.iters
    validate_training_steps(config)
    plan = {"model": str(model_path), "adapter_path": str(output), "config": config, "dataset": manifest}
    if args.dry_run:
        print(json.dumps(plan, indent=2))
        return
    from mlx_lm import load
    from mlx_lm.lora import CONFIG_DEFAULTS, train_model
    from mlx_lm.tuner.datasets import ChatDataset
    import numpy as np

    np.random.seed(config["seed"])
    model, tokenizer = load(
        str(model_path), tokenizer_config={"trust_remote_code": False, "local_files_only": True},
        trust_remote_code=False,
    )
    tokenizer = NonThinkingTokenizer(tokenizer)
    datasets = []
    for split in ("train", "valid"):
        rows = read_jsonl(args.data / f"{split}.jsonl")
        dataset = ChatDataset(rows, tokenizer, mask_prompt=True)
        for index, row in enumerate(rows):
            tokens, offset = dataset.process(row)
            if len(tokens) > config["max_seq_length"] or not 0 < offset < len(tokens):
                raise ValueError(f"{split} record {index}: tokens={len(tokens)}, prompt={offset}, limit={config['max_seq_length']}; check token budget and assistant target")
            prefix = tokenizer.apply_chat_template(
                row["messages"][:-1], add_generation_prompt=True, return_dict=False,
            )
            if tokens[:offset] != prefix:
                raise ValueError("Tokenizer training/inference assistant-prefix boundaries disagree")
        datasets.append(dataset)
    options = SimpleNamespace(**{
        **CONFIG_DEFAULTS, **config, "model": str(model_path),
        "data": str(args.data.resolve()), "adapter_path": str(output), "train": True,
    })
    train_model(options, model, *datasets)
    # Numeric settings and hashes only; no sample text is copied into the run recipe.
    (output / "experiment.json").write_text(json.dumps(plan, indent=2) + "\n")


def evaluate(args):
    cases = read_jsonl(args.cases)
    if not cases:
        raise ValueError("Evaluation requires at least one case")
    generator = Generator(args.model, args.adapter, args.max_tokens)
    # Warm-up has a fresh request/cache; no cross-request context is reused.
    warmup = next((Request.from_dict(case["request"]) for case in cases
                   if Request.from_dict(case["request"]).needs_model), None)
    if warmup:
        generator.generate(warmup)
    scores = []
    categories = {}
    for case in cases:
        score = score_case(case, generator.generate(Request.from_dict(case["request"])))
        scores.append(score)
        categories.setdefault(case["category"], []).append(score)
    import mlx.core as mx

    report = {
        "model_load_ms": generator.load_ms, "peak_mlx_memory_bytes": mx.get_peak_memory(),
        "summary": summarize(scores),
        "by_category": {name: summarize(rows) for name, rows in sorted(categories.items())},
        "timing_scope": "Warm sequential offline requests, fresh cache per request; includes template, generation and validation; excludes model load. First token is not first complete candidate. Not host-app latency.",
        "quality_scope": "Exact language-aware match to ANY authored acceptable candidate, not a calibrated ranking score; synthetic smoke cases, not a general quality benchmark.",
    }
    text = json.dumps(report, indent=2) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        with args.output.open("x", encoding="utf-8") as stream:
            stream.write(text)
    print(text, end="")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("doctor", help="Check installed MLX/Metal without any model")
    convert = commands.add_parser("convert", help="Convert/quantize a local Safetensors snapshot")
    convert.add_argument("--model", required=True)
    convert.add_argument("--output", required=True, type=Path)
    training = commands.add_parser("train")
    training.add_argument("--model", required=True)
    training.add_argument("--source", type=Path, default=ROOT / "data/seeds.jsonl")
    training.add_argument("--data", type=Path, default=ROOT / "data/prepared")
    training.add_argument("--config", type=Path, default=ROOT / "configs/lora.yaml")
    training.add_argument("--output", type=Path, required=True)
    training.add_argument("--iters", type=int)
    training.add_argument("--dry-run", action="store_true")
    for name in ("infer", "evaluate"):
        command = commands.add_parser(name)
        command.add_argument("--model", required=True)
        command.add_argument("--adapter", type=Path)
        command.add_argument("--max-tokens", type=int, default=384)
        if name == "evaluate":
            command.add_argument("--cases", type=Path, default=ROOT / "data/prepared/test.cases.jsonl")
            command.add_argument("--output", type=Path)
    args = parser.parse_args()
    if hasattr(args, "max_tokens") and not 1 <= args.max_tokens <= 2048:
        parser.error("max-tokens must be between 1 and 2048")
    if getattr(args, "iters", None) is not None and args.iters < 1:
        parser.error("iters must be positive")
    try:
        if args.command == "doctor":
            print(json.dumps(doctor(), indent=2))
        elif args.command == "convert":
            check_platform()
            offline_environment()
            path = model_directory(args.model)
            if args.output.exists():
                raise ValueError("Conversion requires a new output directory")
            from mlx_lm import convert as mlx_convert

            mlx_convert(str(path), mlx_path=str(args.output.resolve()), quantize=True, q_bits=4, q_group_size=64)
        elif args.command == "train":
            train(args)
        elif args.command == "infer":
            # Exactly one explicit request; no shell history or chat-history recorder.
            request = Request.from_dict(json.loads(sys.stdin.read(32769)))
            if request.needs_model:
                result = Generator(args.model, args.adapter, args.max_tokens).generate(request)
            else:
                from protocol import finish_candidates
                result = {"candidates": finish_candidates([], request), "status": "bypassed"}
            print(compact(result))
        else:
            evaluate(args)
    except (OSError, ValueError, TypeError, KeyError, ImportError, RuntimeError):
        # Library exceptions can embed input/response text; never echo them.
        parser.exit(1, "Experiment failed: check local model files, dependencies, data/configuration and output paths. Use doctor and prepare.py --check. No request or response was logged.\n")


if __name__ == "__main__":
    main()
