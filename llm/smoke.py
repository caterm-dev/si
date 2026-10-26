"""Exercise prepare -> train -> resume -> validation -> test -> predict on CPU."""

import argparse
from pathlib import Path

from .common import write_json
from .evaluate import evaluate
from .prepare import prepare
from .runtime import candidates, load_checkpoint, select_device
from .train import train


def smoke(output):
    output = Path(output)
    if output.exists():
        raise ValueError("Smoke output exists; choose a new directory")
    output.mkdir(parents=True)
    root = Path(__file__).parent
    config = root / "configs/smoke.json"
    data, run = output / "data", output / "run"
    manifest = prepare(config, root / "configs/sources.json", data)
    train(config, data, run, "cpu", max_steps=2, threads=2)
    train(config, data, run, "cpu", resume=True, max_steps=4, threads=2)
    validation = evaluate(data, "validation", output / "validation.json", run / "best.pt", device_name="cpu", limit=3, threads=2)
    test = evaluate(data, "test", output / "test.json", run / "best.pt", device_name="cpu", limit=3, threads=2)
    evaluate(data, "test", output / "literal.json", config_path=config, baseline="literal", device_name="cpu", limit=3, threads=2)
    _, model, tokenizer = load_checkpoint(run / "best.pt", select_device("cpu"))
    for text in ("nihao", "womenzaijia", "hello", "hlelo", ""):
        result = candidates(model, tokenizer, text, select_device("cpu"), 2, 0.6)
        if text and text not in result["candidates"]:
            raise AssertionError("Literal fallback was lost")
        if not text and result["candidates"]:
            raise AssertionError("Empty input produced candidates")
    summary = {"status": "passed", "dataset_id": manifest["dataset_id"],
               "steps": 4, "validation_cases": validation["evaluated_cases"], "test_cases": test["evaluated_cases"],
               "note": "Tiny random model, partial synthetic evaluation; this establishes pipeline execution only."}
    write_json(output / "summary.json", summary)
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    print(smoke(args.output))


if __name__ == "__main__":
    main()
