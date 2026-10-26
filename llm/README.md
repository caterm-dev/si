# SI spelling-to-text training

The current workflow uses **maintained static CSV files**. Folder names choose train/validation/test; CSV filenames choose source groups. Preparation imports exactly those rows. It does not generate sentences, spelling errors, Pinyin or random splits.

The default model is a randomly initialized **403,069,952-parameter (0.403B) encoder–decoder Transformer**. This experimental framework is separate from the macOS input method. Conversion quality and deployment remain unproven.

## Maintain the data

```text
llm/data/csv/
  provenance.json
  train/
    city.csv
    company.csv
    chat_daily.csv
    typos.csv
    english.csv
    ...
  validation/
    city.csv
    chat_daily.csv
    ...
  test/
    city.csv
    chat_daily.csv
    ...
```

Chinese files need only two columns:

```csv
input,target
beijing,北京
shanghai,上海
```

`input` is the actual spelling typed; `target` is the exact desired output. To maintain errors, add explicit rows such as `nihaoo,你好` to `typos.csv`. Correct vocabulary remains in files such as `city.csv` and `company.csv`. No auxiliary fields such as `group`, `clean_input` or `noise` need to be edited.

An optional third column `language` supports `zh`, `en` and `mixed`; the default is `zh`. Existing English/mixed files supply it. Use UTF-8 CSV; a UTF-8 BOM and quoted commas are supported. Empty fields, invalid column counts, unknown columns/languages, controls and oversized sequences fail before an output dataset is published. Whitespace/casing in valid values is preserved.

Add as many CSVs as needed, including nested paths such as `train/business/company.csv`. Files are discovered automatically; no Python or per-file registration changes are required. `city.csv` may exist in every split: it labels the domain, not a leakage-prevention hash. Put related spellings/sentence variants into the same split yourself. Normalized-identical input or target text across splits is rejected with both source locations; preparation does not silently move rows. Identical pairs within one split are deduplicated while retaining their source memberships.

See [the source data guide](data/csv/README.md) for the full contract and current counts. `provenance.json` declares the license/public origin/revision for SI-authored data and optional per-file overrides. Its default declaration applies to new files; it does not grant rights to unrelated third-party data. Review and declare any imported source before adding it. Private input, personal phrases and app history are not training sources.

## Setup and quick checks

Run from the repository root:

```sh
./llm/scripts/setup.sh
./llm/scripts/check.sh
./llm/scripts/smoke.sh
```

Setup creates/reuses isolated `llm/.venv` with Python 3.12 and pinned PyTorch/NumPy/pypinyin. Scripts use it without activation and resolve relative arguments from the repository root, even when launched from another directory. `--help` is available on each entry point. Setup options include `--python`, `--venv`, `--offline`, `--find-links` and `--torch-index-url`; `SI_LLM_VENV` selects the environment for later scripts, while `SI_LLM_PYTHON` overrides an already managed runtime interpreter. CUDA wheel-index installation is not hardware-verified.

Smoke imports the static CSV collection, trains/resumes the small CPU model for four total steps and performs partial validation/test plus literal fallback checks. It does not run the 0.4B model or generate corpus content. With no arguments it uses a fresh timestamped output directory; use `--output NEW_DIRECTORY` for an explicit location. The small check is not a conversion-quality benchmark.

## Prepare a frozen version

```sh
./llm/scripts/prepare.sh --output llm/data/prepared/static-csv-v2
```

The default source is `llm/data/csv/`; override it with `--csv-root PATH`. The default model configuration is `llm/configs/0.4b-static-csv.json`; use `--config PATH` for a different tokenizer/sequence-size setup. Existing output directories are never replaced.

The result contains `train.jsonl`, `validation.jsonl`, `test.jsonl`, a train-only tokenizer, a manifest and exact CSV snapshots under `source_csv/`. JSONL is an internal training format; maintain the source CSVs. The manifest records source-file hashes, counts, groups, licenses and the dataset identity. Preparation performs no augmentation, regardless of legacy noise/split-ratio fields in a shared config. The tokenizer uses Unicode character tokens with lossless UTF-8 byte fallback and never silently truncates labels.

Editing a source CSV does not change an existing prepared snapshot. Prepare a new version before training on edits. Do not edit the compiled files or tokenizer in a prepared directory.

## Train or resume

Start a fresh 0.4B experiment against the prepared version:

```sh
./llm/scripts/train.sh --data llm/data/prepared/static-csv-v2 \
  --run llm/runs/0.4b-static-csv-v2 --device mps --threads 4
```

Continue the same unchanged experiment after stopping it:

```sh
./llm/scripts/resume.sh --data llm/data/prepared/static-csv-v2 \
  --run llm/runs/0.4b-static-csv-v2 --device mps --threads 4
```

The new default config keeps the 0.403B architecture, FP32, batch size 2, accumulation 4 and a 2,000-step stage. It validates every 100 steps and saves every 25. Use `cpu`, `mps`, `cuda` or `auto`; BF16 requires supported CUDA hardware. FP32 weights occupy 1,612,279,808 bytes; weights/gradients/Adam moments total about 6,449,119,232 bytes before activations and other overhead. These are parameter estimates, not measured peak device memory. Training is single-device and holds rows/token tensors in memory.

Training reads only train/validation. `last.pt` preserves the model, optimizer, RNG and batch position; `best.pt` is selected by validation loss. Control+C stops the foreground trainer, and resume restarts from the latest completed saved step. A source edit needs a new prepared version and new experiment. Resume requires unchanged runtime code, dataset, tokenizer, config, PyTorch version, device type and thread count. `--max-steps N` may extend a run without changing its original learning-rate schedule. Never run concurrent trainers on the same run directory.

## Validate, test and infer

Use validation while developing and test after choosing an experiment. Choose new report filenames each time:

```sh
./llm/scripts/validation.sh --checkpoint llm/runs/0.4b-static-csv-v2/best.pt \
  --data llm/data/prepared/static-csv-v2 --output llm/reports/csv-v2-validation.json --device mps
./llm/scripts/test.sh --checkpoint llm/runs/0.4b-static-csv-v2/best.pt \
  --data llm/data/prepared/static-csv-v2 --output llm/reports/csv-v2-test.json --device mps
./llm/scripts/infer.sh --checkpoint llm/runs/0.4b-static-csv-v2/best.pt \
  --input womenzaijia --device mps
```

`model_candidates` contains model outputs; `candidates` additionally retains the exact literal input. Candidates are unconstrained text hypotheses, so model scores do not guarantee matching Pinyin. Empty input returns no candidates. Invalid/incomplete UTF-8 and control outputs are discarded. The bounded beam can return fewer than k valid outputs.

Reports include top-1, top-k recall, code-point character error rate and exact-copy error rate, with literal fallback reported separately. Imported CSV rows are labeled `provided` internally because a two-column source does not declare an error type; exact identity pairs are recognized as clean-copy fixtures. The collection does not invent clean spellings/error categories for arbitrary pairs. `--limit N` marks evaluation partial. Offline p50/p95 timing is not a host-app latency claim.

Additional entry points:

| Script | Purpose |
| --- | --- |
| `size.sh` | Count parameters on the meta device without full allocation |
| `export.sh` | Strip optimizer/RNG state for inference export |
| `compare.sh` | Compare reports with matching dataset/split/cases/k |
| `sources.sh` | Historical public JSONL source registration |

`make -C llm` targets use the same scripts: `setup`, `check`, `smoke`, `size`, `prepare`, `train`, `resume`, `validation`/`evaluate`, `test`, `infer`/`predict` and `export`. Override `CSV_ROOT`, `CONFIG`, `DATA`, `RUN`, `REPORT`, `DEVICE` or `SMOKE_OUTPUT`. Optional `PYTHON` sets the runtime interpreter. Aggregate logs do not include sample text or generated predictions; `infer.sh` prints the requested result locally.

## Existing checkpoints and historical data

The previous `chinese-starter-v1` prepared directory and optimizer checkpoints remain available. The new CSV importer lives in a separate package and leaves the existing training-runtime identity unchanged. To continue an old run, explicitly supply its original configuration and prepared directory; the new CSV dataset cannot be substituted into that run.

```sh
./llm/scripts/resume.sh --config llm/configs/0.4b-chinese-starter-v1.json \
  --data llm/data/prepared/chinese-starter-v1 --run llm/runs/chinese-starter-v1 \
  --device mps --threads 4
```

Old `seed.json`/template generation, automatic JSONL splitting and keyboard-noise augmentation are retained only for historical reproduction and regression coverage. They are not called by the current CSV preparation/smoke scripts. `generate_data.sh` now explains this change and exits; an explicit `prepare.sh --sources LEGACY_MANIFEST` still routes to the legacy importer. Direct `python -m llm.prepare` / `llm.smoke` are historical entry points. The archived [Chinese starter documentation](data/chinese-starter/README.md) records the initial dataset and MPS repair.

## Scope and dependency rights

SI code/data retain GPLv3. Training tools are separately installed, not linked into the macOS input method: [PyTorch 2.6.0](https://github.com/pytorch/pytorch/tree/v2.6.0) uses [BSD-style terms](https://github.com/pytorch/pytorch/blob/v2.6.0/LICENSE), [NumPy 2.2.6](https://pypi.org/project/numpy/2.2.6/) uses BSD terms, and [pypinyin 0.55.0](https://github.com/mozillazg/python-pinyin/tree/v0.55.0) uses [MIT terms](https://github.com/mozillazg/python-pinyin/blob/v0.55.0/LICENSE.txt). pypinyin is retained for historical reproduction; static CSV import does not call it. Preserve dependency/bundled-binary notices on redistribution. These pins are not a cross-platform transitive lockfile.

The model is experimental. Broad vocabulary coverage, representative real-typo evaluation, strict spelling-constrained generation and native deployment remain separate work. Language-aware candidate identity, enabled-language coexistence, source/output alignment, prefix commits and cancellation remain SI's core/controller contracts. No trained model is integrated into the input method.
