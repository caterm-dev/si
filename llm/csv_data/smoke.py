"""Check static CSV import, small CPU training/resume and candidate evaluation."""

import argparse
from pathlib import Path

from ..common import write_json
from ..evaluate import evaluate
from ..runtime import candidates, load_checkpoint, select_device
from ..train import train
from .prepare import ROOT, prepare


def smoke(output, csv_root):
    output = Path(output)
    if output.exists():
        raise ValueError("Smoke output exists; choose a new directory")
    output.mkdir(parents=True)
    config = ROOT / "configs/smoke.json"
    data, run = output / "data", output / "run"
    manifest = prepare(config, csv_root, data)
    train(config, data, run, "cpu", max_steps=2, threads=2)
    train(config, data, run, "cpu", resume=True, max_steps=4, threads=2)
    validation = evaluate(data, "validation", output / "validation.json", run / "best.pt", device_name="cpu", limit=3, threads=2)
    test = evaluate(data, "test", output / "test.json", run / "best.pt", device_name="cpu", limit=3, threads=2)
    evaluate(data, "test", output / "literal.json", config_path=config, baseline="literal", device_name="cpu", limit=3, threads=2)
    _, model, tokenizer = load_checkpoint(run / "best.pt", select_device("cpu"))
    for spelling in ("nihao", "womenzaijia", "HelloWorld42", ""):
        result = candidates(model, tokenizer, spelling, select_device("cpu"), 2, .6)
        assert (spelling in result["candidates"]) if spelling else not result["candidates"]
    summary = {"status": "passed", "data_format": "static-csv", "dataset_id": manifest["dataset_id"],
               "source_files": len(manifest["sources"]), "steps": 4,
               "validation_cases": validation["evaluated_cases"], "test_cases": test["evaluated_cases"],
               "note": "Small CPU workflow check; no text/noise generation or random split, no 0.4B quality claim."}
    write_json(output / "summary.json", summary)
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--csv-root", type=Path, default=ROOT / "data/csv")
    args = parser.parse_args()
    print(smoke(args.output, args.csv_root))


if __name__ == "__main__":
    main()
