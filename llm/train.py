"""Train from scratch or resume the same experiment; never open the test split."""

import argparse
import contextlib
import datetime
import json
import math
import random
import subprocess
from pathlib import Path

import torch
from torch.nn import functional as F

from .common import canonical_bytes, file_hash, fingerprint, load_config, write_json
from .model import SpellingTransformer
from .runtime import atomic_checkpoint, collate, load_bundle, seed_everything, select_device, tensors
from .tokenizer import PAD


def code_identity():
    return fingerprint({p.name: file_hash(p) for p in sorted(Path(__file__).parent.glob("*.py"))})


def resume_identity(config):
    immutable = json.loads(json.dumps(config))
    # Extending a run does not change its original learning-rate schedule.
    del immutable["training"]["max_steps"]
    return fingerprint(immutable)


def learning_rate(step, settings):
    if step <= settings["warmup_steps"]:
        return settings["learning_rate"] * step / settings["warmup_steps"]
    progress = min(1.0, (step - settings["warmup_steps"]) / (settings["schedule_steps"] - settings["warmup_steps"]))
    return settings["learning_rate"] * (0.1 + 0.9 * (1 + math.cos(math.pi * progress)) / 2)


def autocast(device, precision):
    return torch.autocast("cuda", dtype=torch.bfloat16) if precision == "bf16" else contextlib.nullcontext()


@torch.inference_mode()
def validation_loss(model, examples, settings, device):
    model.eval()
    total, count = 0.0, 0
    for offset in range(0, len(examples), settings["batch_size"]):
        source, decoder, labels = collate(examples[offset:offset + settings["batch_size"]], device)
        with autocast(device, settings["precision"]):
            logits = model(source, decoder)
            loss = F.cross_entropy(logits.flatten(0, 1).float(), labels.flatten(), ignore_index=PAD, reduction="sum")
        total += float(loss)
        count += int(labels.ne(PAD).sum())
    model.train()
    return total / count


def train(config_path, data_path, run_path, device_name="auto", resume=False, max_steps=None, threads=4):
    config = load_config(config_path)
    if max_steps is not None:
        if max_steps <= 0:
            raise ValueError("max_steps must be positive")
        config["training"]["max_steps"] = max_steps
    if threads <= 0:
        raise ValueError("threads must be positive")
    torch.set_num_threads(threads)
    settings = config["training"]
    device = select_device(device_name)
    if settings["precision"] == "bf16" and (device.type != "cuda" or not torch.cuda.is_bf16_supported()):
        raise ValueError("bf16 requires a CUDA device with BF16 support; use fp32 on CPU/MPS")
    seed_everything(config["seed"])
    manifest, tokenizer, rows = load_bundle(data_path, config, ("train", "validation"))
    train_data = tensors(rows["train"], tokenizer, config["model"])
    validation = tensors(rows["validation"], tokenizer, config["model"])
    if not train_data or not validation:
        raise ValueError("Training and validation splits must both be nonempty")
    run_path = Path(run_path)
    checkpoint = None
    code_id = code_identity()
    if resume:
        checkpoint = torch.load(run_path / "last.pt", map_location="cpu", weights_only=True)
        if (checkpoint["dataset_id"] != manifest["dataset_id"]
                or checkpoint["tokenizer_digest"] != tokenizer.digest
                or checkpoint["resume_identity"] != resume_identity(config)
                or checkpoint["code_identity"] != code_id):
            raise ValueError("Resume requires identical code, dataset, tokenizer and configuration except max_steps")
        if (checkpoint["device_type"] != device.type or checkpoint["torch_version"] != str(torch.__version__)
                or checkpoint["threads"] != threads):
            raise ValueError("Resume requires the original device type, thread count and PyTorch version; start a new run")
        if checkpoint["step"] >= settings["max_steps"]:
            raise ValueError("Checkpoint already reached max_steps; raise --max-steps to continue")
    elif run_path.exists():
        raise ValueError("Run directory already exists; choose a new name or use --resume")
    else:
        run_path.mkdir(parents=True)
    model = SpellingTransformer(config["model"], tokenizer.active_ids, settings["activation_checkpointing"]).to(device)
    optimizer = torch.optim.AdamW(model.parameters(), lr=settings["learning_rate"], weight_decay=settings["weight_decay"])
    step, epoch, cursor, best = 0, 0, 0, float("inf")
    if checkpoint:
        model.load_state_dict(checkpoint["model"])
        optimizer.load_state_dict(checkpoint["optimizer"])
        step, epoch, cursor, best = (checkpoint[key] for key in ("step", "epoch", "cursor", "best_validation_loss"))
        random.setstate(checkpoint["python_rng"])
        torch.set_rng_state(checkpoint["torch_rng"])
        if device.type == "cuda":
            torch.cuda.set_rng_state_all(checkpoint["accelerator_rng"])
        elif device.type == "mps":
            torch.mps.set_rng_state(checkpoint["accelerator_rng"])
        # The model/optimizer now own the restored state. Do not retain another
        # CPU checkpoint copy for the lifetime of an accelerator training run.
        del checkpoint
    else:
        revision = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True, check=False).stdout.strip()
        write_json(run_path / "run.json", {
            "schema_version": 1, "created_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "config": config, "dataset_id": manifest["dataset_id"], "tokenizer_digest": tokenizer.digest,
            "code_identity": code_id, "git_revision": revision, "torch_version": str(torch.__version__),
            "device": str(device), "threads": threads, "parameters": sum(p.numel() for p in model.parameters()),
            "initialization": "random; no pretrained weights", "sources": manifest["sources"],
        })
    model.train()

    def log(value):
        with (run_path / "metrics.jsonl").open("ab") as stream:
            stream.write(canonical_bytes(value) + b"\n")
        print(json.dumps(value), flush=True)

    def save(name):
        accelerator_rng = torch.cuda.get_rng_state_all() if device.type == "cuda" else torch.mps.get_rng_state() if device.type == "mps" else None
        atomic_checkpoint(run_path / name, {
            "schema_version": 1, "config": config, "dataset_id": manifest["dataset_id"],
            "tokenizer": tokenizer.to_dict(), "tokenizer_digest": tokenizer.digest,
            "resume_identity": resume_identity(config), "code_identity": code_id,
            "device_type": device.type, "torch_version": str(torch.__version__),
            "threads": threads,
            "model": model.state_dict(), "optimizer": optimizer.state_dict(),
            "step": step, "epoch": epoch, "cursor": cursor, "best_validation_loss": best,
            "python_rng": random.getstate(), "torch_rng": torch.get_rng_state(), "accelerator_rng": accelerator_rng,
        })

    log({"event": "resume" if resume else "start", "step": step, "target_steps": settings["max_steps"]})
    order = None
    while step < settings["max_steps"]:
        optimizer.zero_grad(set_to_none=True)
        accumulated = 0.0
        for _ in range(settings["gradient_accumulation"]):
            if cursor >= len(train_data):
                epoch += 1
                cursor = 0
                order = None
            if order is None:
                generator = torch.Generator().manual_seed(config["seed"] + epoch)
                order = torch.randperm(len(train_data), generator=generator).tolist()
            indices = order[cursor:cursor + settings["batch_size"]]
            cursor += len(indices)
            source, decoder, labels = collate([train_data[i] for i in indices], device)
            with autocast(device, settings["precision"]):
                logits = model(source, decoder)
                loss = F.cross_entropy(logits.flatten(0, 1).float(), labels.flatten(), ignore_index=PAD)
            if not torch.isfinite(loss):
                raise RuntimeError("Nonfinite training loss; the previous checkpoint remains available")
            accumulated += float(loss.detach()) / settings["gradient_accumulation"]
            (loss / settings["gradient_accumulation"]).backward()
        torch.nn.utils.clip_grad_norm_(model.parameters(), settings["gradient_clip"], error_if_nonfinite=True)
        step += 1
        rate = learning_rate(step, settings)
        for group in optimizer.param_groups:
            group["lr"] = rate
        optimizer.step()
        metrics = {"event": "step", "step": step, "epoch": epoch, "loss": accumulated, "learning_rate": rate}
        if step % settings["validate_every"] == 0 or step == settings["max_steps"]:
            value = validation_loss(model, validation, settings, device)
            if not math.isfinite(value):
                raise RuntimeError("Nonfinite validation loss")
            metrics["validation_loss"] = value
            if value < best:
                best = value
                save("best.pt")
        log(metrics)
        if step % settings["save_every"] == 0 or step == settings["max_steps"]:
            save("last.pt")
    return {"step": step, "best_validation_loss": best, "run": str(run_path)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=Path("llm/configs/0.4b.json"))
    parser.add_argument("--data", type=Path, required=True)
    parser.add_argument("--run", type=Path, required=True)
    parser.add_argument("--device", choices=("auto", "cpu", "mps", "cuda"), default="auto")
    parser.add_argument("--resume", action="store_true")
    parser.add_argument("--max-steps", type=int)
    parser.add_argument("--threads", type=int, default=4)
    args = parser.parse_args()
    print(train(args.config, args.data, args.run, args.device, args.resume, args.max_steps, args.threads))


if __name__ == "__main__":
    main()
