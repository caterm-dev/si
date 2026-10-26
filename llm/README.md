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
    words.csv
    chat.csv
    typos.csv
    english.csv
    ...
  validation/
    city.csv
    chat.csv
    ...
  test/
    city.csv
    chat.csv
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

The current source contains 50,000 unique samples (47,339 train, 1,361 validation, 1,300 test). The [expansion record](data/csv/EXPANSION_50K.md) documents 31,027 new synthetic training pairs, provenance and checks. All original samples and validation/test files are preserved. The expanded immutable bundle is `llm/data/prepared/static-csv-50k-v1`; select it explicitly with a fresh run rather than resuming an older dataset. Shared presets still point to the existing `static-csv-v2` experiment.

## Setup and quick checks

Each entry point performs one task. Parameters are preset; run the commands separately when you need that stage:

| Command | Only task |
| --- | --- |
| `./llm/scripts/setup.sh` | Install/check the Python environment |
| `./llm/scripts/data.sh` | Prepare the current CSV data (`prepare.sh` is the same entry point) |
| `./llm/scripts/run.sh` | Start fresh 0.4B training (`train.sh` is the same entry point) |
| `./llm/scripts/resume.sh` | Resume the existing training run |
| `./llm/scripts/validation.sh` | Evaluate the complete validation split |
| `./llm/scripts/test.sh` | Evaluate the complete test split |
| `./llm/scripts/infer.sh --input womenzaijia` | Inspect candidates for one input (default input: `nihao`) |
| `./llm/scripts/export.sh` | Export inference weights |

No entry point automatically launches the next stage or setup. Training retains its periodic validation-loss calculation and checkpoint saving; separate candidate evaluation requires an explicit validation/test command.

[Shared presets](scripts/defaults.sh) select the 0.403B configuration, MPS, four CPU threads, the current CSV root, `llm/data/prepared/static-csv-v2/`, `llm/runs/0.4b-static-csv-v2/` and `llm/reports/0.4b-static-csv-v2/{validation,test}.json`. Training uses 2,000 steps from the model config. Evaluation/inference/export read the run's `best.pt`; export writes `inference.pt` beside it.

Edit the presets once to use different paths, or override individual command arguments as shown below. Optional environment overrides are `SI_LLM_EXPERIMENT`, `SI_LLM_CONFIG`, `SI_LLM_CSV_ROOT`, `SI_LLM_DATA`, `SI_LLM_RUN`, `SI_LLM_REPORT_ROOT`, `SI_LLM_CHECKPOINT`, `SI_LLM_DEVICE` and `SI_LLM_THREADS`. Changing `SI_LLM_EXPERIMENT` selects matching default data/run/report paths. Explicit command arguments take precedence over presets. Relative paths resolve from the repository root.

Preparation and fresh training reject existing output directories. To train edited CSVs, choose a new experiment name in the presets (for example, `static-csv-v3`), then run data preparation and training separately. To continue an unchanged run, use `resume.sh`. Evaluation also rejects existing report paths; use `--output NEW_PATH` to retain earlier reports. Control+C stops the foreground task and does not start another stage.

Run from the repository root:

```sh
./llm/scripts/setup.sh
./llm/scripts/check.sh
./llm/scripts/smoke.sh
```

Setup creates/reuses isolated `llm/.venv` with Python 3.12 and pinned PyTorch/NumPy. Scripts use it without activation and resolve relative arguments from the repository root, even when launched from another directory. `--help` is available on each entry point. Setup options include `--python`, `--venv`, `--offline`, `--find-links` and `--torch-index-url`; `SI_LLM_VENV` selects the environment for later scripts, while `SI_LLM_PYTHON` overrides an already managed runtime interpreter. CUDA wheel-index installation is not hardware-verified.

Smoke imports the static CSV collection, trains/resumes the small CPU model for four total steps and performs partial validation/test plus literal fallback checks. It does not run the 0.4B model or generate corpus content. With no arguments it uses a fresh timestamped output directory; use `--output NEW_DIRECTORY` for an explicit location. The small check is not a conversion-quality benchmark.

## Prepare a frozen version

```sh
./llm/scripts/prepare.sh --output llm/data/prepared/static-csv-v2
```

The default source is `llm/data/csv/`; override it with `--csv-root PATH`. The default model configuration is `llm/configs/0.4b-static-csv.json`; use `--config PATH` for a different tokenizer/sequence-size setup. Existing output directories are never replaced.

The result contains `train.jsonl`, `validation.jsonl`, `test.jsonl`, a train-only tokenizer, a manifest and exact CSV snapshots under `source_csv/`. JSONL is an internal training format; maintain the source CSVs. The manifest records source-file hashes, counts, groups, licenses and the dataset identity. The config declares `data.format` as `static-csv`; automatic split/noise options are not supported. The tokenizer uses Unicode character tokens with lossless UTF-8 byte fallback and never silently truncates labels.

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

For an independent frozen benchmark, create a CSV root with `provenance.json` and `test/*.csv` (or `validation/*.csv` for validation), then pass `--benchmark PATH` alongside the model's matching `--data` bundle. Only the selected benchmark split is read. Its normalized input/target overlap with that run's train/validation is rejected. Models trained on different CSV versions can be compared against the same frozen benchmark identity.

Additional entry points:

| Script | Purpose |
| --- | --- |
| `size.sh` | Count parameters on the meta device without full allocation |
| `export.sh` | Strip optimizer/RNG state for inference export |
| `compare.sh` | Compare reports with matching dataset/split/cases/k |

`make -C llm` targets use the same scripts: `setup`, `check`, `smoke`, `size`, `data`/`prepare`, `run`/`train`, `resume`, `validation`/`evaluate`, `test`, `infer`/`predict` and `export`. Targets accept `CSV_ROOT`, `CONFIG`, `DATA`, `RUN`, `REPORT`, `DEVICE` or `SMOKE_OUTPUT`. Make variable overrides apply to that invocation; use the same values for related stages. Optional `PYTHON` sets the runtime interpreter. Aggregate logs do not include sample text or generated predictions; `infer.sh` prints the requested result locally.

## Preserved trained weights

Old source data, generators, JSONL-source manifests, obsolete configs and their smoke artifacts have been deleted. Maintained CSVs and current prepared CSV versions are the data workflow.

The previously trained weights and run records remain under `llm/runs/chinese-starter-v1/`. They can still be loaded for inference/export without the removed data:

```sh
./llm/scripts/infer.sh --checkpoint llm/runs/chinese-starter-v1/best.pt \
  --input womenzaijia --device mps
```

Those old experiments can no longer be resumed: their source/prepared data and compatible training setup were removed. Start a new run from the current CSV snapshot for further training. Checkpoint identity checks remain strict; the cleanup does not relabel old weights as having trained on the new dataset.

## Scope and dependency rights

SI code/data retain GPLv3. Training tools are separately installed, not linked into the macOS input method: [PyTorch 2.6.0](https://github.com/pytorch/pytorch/tree/v2.6.0) uses [BSD-style terms](https://github.com/pytorch/pytorch/blob/v2.6.0/LICENSE), [NumPy 2.2.6](https://pypi.org/project/numpy/2.2.6/) uses BSD terms. The retired pronunciation-generation dependency is no longer installed or required. Preserve dependency/bundled-binary notices on redistribution. These pins are not a cross-platform transitive lockfile.

The model is experimental. Broad vocabulary coverage, representative real-typo evaluation, strict spelling-constrained generation and native deployment remain separate work. Language-aware candidate identity, enabled-language coexistence, source/output alignment, prefix commits and cancellation remain SI's core/controller contracts. No trained model is integrated into the input method.
