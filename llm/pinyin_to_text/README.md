# SI Pinyin-to-text training

This guide covers the converter in the [model workspace](../README.md).
The sibling small/large reranker directories are separate model families.
The old root Pinyin/correction suites and `eval.adapters converter` were retired
on November 9, 2026. The new [root test set](../../eval/README.md) covers ranking
queries only; converter-specific training, validation and test tools remain here.
Python dependencies and the existing environment remain shared at `llm/requirements.txt`
and `llm/.venv`; all converter-specific files and artifacts live here.

The default experiment trains a randomly initialized **19,711,488-parameter encoder-decoder** with explicit Pinyin syllable sequences and optional preceding text. This workflow prepares and trains an offline converter. See the [input ranking build](../README.md#experimental-input-ranking) for native integration.

## Active data

The [100,000-example collection](data/syllable-csv/README.md) contains **96,000 training, 2,000 validation and 2,000 test rows**. Each split has an `examples.csv` file for the first batch and an `additional.csv` file for the second batch.

```csv
input,target,context,syllables
ni,你,,ni
nihao,你好,,ni hao
gongheguo,共和国,中华人民,gong he guo
```

Each `input` concatenates the space-separated lowercase, toneless `syllables`. The `context` column may be empty. The collection includes 90,000 standalone Chinese lexical rows and 10,000 context rows cut from longer dictionary entries with explicit aligned readings. The [source guide](data/syllable-csv/README.md) describes provenance and sampling limits. Preparation freezes the CSVs, checks split separation and fits the tokenizer on training rows.

## Separate preset commands

Each script performs one task. Run these separately from any working directory:

| Command from repository root | Task |
| --- | --- |
| `./llm/pinyin_to_text/scripts/setup.sh` | Prepare the isolated Python environment |
| `./llm/pinyin_to_text/scripts/data.sh` | Freeze the active CSV data (`prepare.sh` alias) |
| `./llm/pinyin_to_text/scripts/run.sh` | Start a new syllable-model run (`train.sh` alias) |
| `./llm/pinyin_to_text/scripts/resume.sh --max-steps 3000` | Extend the same unchanged run to a total step count |
| `./llm/pinyin_to_text/scripts/validation.sh` | Evaluate the complete validation split |
| `./llm/pinyin_to_text/scripts/test.sh` | Evaluate the complete test split after model selection |
| `./llm/pinyin_to_text/scripts/infer.sh --input nihao --syllables 'ni hao'` | Inspect one input with explicit syllables |
| `./llm/pinyin_to_text/scripts/export.sh` | Export inference weights from `best.pt` |
| `./llm/pinyin_to_text/scripts/size.sh` | Count parameters without allocating model weights |
| `./llm/pinyin_to_text/scripts/check.sh` | Run framework regressions using tiny fixtures |
| `./llm/pinyin_to_text/scripts/smoke.sh` | Run a four-step tiny CPU workflow check |

No ordinary stage automatically invokes setup or the next stage. Training retains periodic validation loss and checkpoints; separate candidate validation/test require explicit commands. Smoke is an explicit development check using a tiny model, not the configured 19.7M model.

[defaults.sh](scripts/defaults.sh) now selects:

| Preset | Location/value |
| --- | --- |
| Model | `llm/pinyin_to_text/configs/contextual-pinyin.json` |
| CSV source | `llm/pinyin_to_text/data/syllable-csv/` |
| Prepared bundle | `llm/pinyin_to_text/data/prepared/pinyin-syllable-100k-v1/` |
| Run | `llm/pinyin_to_text/runs/small-pinyin-syllable-100k-v1/` |
| Reports | `llm/pinyin_to_text/reports/small-pinyin-syllable-100k-v1/{validation,test}.json` |
| Device / threads | MPS / 4 |

Old `SI_LLM_*` environment overrides still take precedence. Use a fresh terminal, or unset old experiment/config/data/run/CSV/report/checkpoint overrides before using the new presets. Keep a terminal's chosen experiment consistent across stages. Relative paths resolve from the repository root.

Preparation and fresh training refuse existing output directories. Edit the experiment name in `defaults.sh`, or set `SI_LLM_EXPERIMENT=pinyin-syllable-100k-v2`, to use matching new data/run/report paths after CSV edits. Do not replace an existing run's bundle. `SI_LLM_CONFIG`, `SI_LLM_CSV_ROOT`, `SI_LLM_DATA`, `SI_LLM_RUN`, `SI_LLM_REPORT_ROOT`, `SI_LLM_CHECKPOINT`, `SI_LLM_DEVICE` and `SI_LLM_THREADS` override individual defaults; explicit CLI arguments override those presets.

## Model and training budget

[contextual-pinyin.json](configs/contextual-pinyin.json) uses four encoder and four decoder layers, width 384, eight attention heads, feed-forward width 1,536 and vocabulary capacity 8,192. Source and target limits are 96 and 32 tokens. Source encoding reserves space for the entire syllable sequence and keeps the preceding text that fits. The model retains sinusoidal positions, pre-normalization, shared embedding/output weights, causal decoding and literal fallback. It does not add spelling-constrained decoding or a copy branch.

FP32 weights occupy **78,845,952 bytes (78.85 MB)**. Parameter storage for weights, gradients and Adam moments is approximately 315.38 MB, excluding activations, attention, allocator/runtime and checkpoint overhead. These are arithmetic estimates, not peak-memory measurements.

The initial budget is 2,000 steps, batch 16, accumulation 1, learning rate 0.0003, warmup 50, validation/save every 100, FP32 and dropout 0.1. Activation checkpointing is off for this smaller model. This is an experiment budget, not an accuracy guarantee. `loss` is the current microbatch/accumulation average, not full training-set accuracy. Validation loss uses correct target prefixes; actual candidate accuracy requires generation. Homophones can have multiple valid outputs, so one input does not identify a unique character without context/frequency information.

Training reads train/validation only. `best.pt` is selected by validation loss and `last.pt` retains optimizer/RNG/cursor state. Control+C stops the foreground task. Resume requires unchanged code, data, tokenizer, model/config except `max_steps`, device type, PyTorch and threads. Extending `--max-steps` preserves the original schedule; it does not restart learning-rate decay. A changed model or dataset needs a new run. The old 0.4B weights cannot initialize/resume this architecture through these scripts.

### MPS checkpoint/dropout correction

An October 27, 2026 audit reproduced incorrect gradients with the pinned PyTorch 2.6 MPS backend when dropout and activation checkpointing were both enabled, as in the earlier 0.4B config. The [upstream checkpoint implementation](https://github.com/pytorch/pytorch/blob/v2.6.0/torch/utils/checkpoint.py) gates accelerator RNG preservation on an `_initialized` attribute absent from `torch.mps`. Forward output and loss can match ordinary execution while backward recomputation uses different dropout masks. The earlier zero-dropout MPS test could not catch this.

The model now explicitly captures each checkpointed layer's MPS random state, replays it during recomputation and restores the backward caller's state, including early-stop unwinding and repeated backward. CPU/CUDA retain native checkpoint RNG handling. Nonzero-dropout regressions compare every parameter gradient and RNG state against execution without checkpointing.

This corrects future training updates; it does not repair already trained weights or establish conversion quality. Existing weights remain loadable for inference. Strict code-identity checks intentionally reject resuming a pre-fix run; preserve it and select a new experiment name/config/data path for a new run. Do not overwrite its checkpoints or edit their identity metadata. Validation loss is teacher-forced token loss, not complete-output accuracy; the small overfit tests and script smoke checks are not evidence that the full corpus has been learned.

## Evaluation and inference

Evaluation reports top-1 exact accuracy, top-k recall, code-point character error rate and exact-copy error rate, with literal fallback reported separately. The active Pinyin-only corpus has no English identity fixtures; a zero-case copy metric is unavailable rather than evidence of copy correctness. Reports group identical inputs and accept any listed reference. Candidates are still unconstrained hypotheses; they may mismatch Pinyin. Empty input yields no candidates, and every nonempty input retains exact literal fallback. Invalid/incomplete UTF-8 and control output are rejected.

Use a new output path for repeated validation, for example:

```sh
./llm/pinyin_to_text/scripts/validation.sh --output llm/pinyin_to_text/reports/small-pinyin-syllable-100k-v1/validation-step1000.json
```

`--limit N` explicitly marks a partial report. An external benchmark can be supplied with `--benchmark PATH` containing provenance and the selected split's CSVs; its inputs/targets must not overlap that model's train/validation. `compare.sh` requires matching dataset/split/cases/k. Offline p50/p95 timings are not host-app latency claims. The small workflow checks and bounded memorization probes do not establish held-out conversion accuracy.

## Contextual Pinyin experiment

The encoder reads preceding text, a dedicated Pinyin start token and a
space-separated syllable sequence. Inference accepts up to three paths,
batches the encoder inputs and active beams, and merges duplicate outputs
by their best normalized beam score. It always preserves the original
spelling as a candidate. Evaluation keeps separate references for each
context and shares a spelling's annotated paths across its contexts.

```sh
./llm/pinyin_to_text/scripts/infer.sh --input fangan --context '先定个' \
    --syllables 'fang an' --syllables 'fan gan'
```

The [small smoke fixtures](data/contextual-pinyin-csv/train/examples.csv)
contain six train, three validation and three test examples. Run
`./llm/pinyin_to_text/scripts/smoke.sh` for the tiny CPU workflow check.
Use `SI_LLM_EXPERIMENT=pinyin-contextual-v1` to explicitly prepare the same
fixtures with the 19.7M config. The dictionary-derived dataset and smoke
fixtures measure conversion with supplied paths. Production segmentation
quality requires separate evaluation.

## Previous experiments and dependencies

The continuous-spelling CSV collections and prepared bundles were retired. The earlier 0.403B dataset provenance is recorded in Git history at `e6c5451:llm/pinyin_to_text/data/csv/EXPANSION_50K.md`. If you have an existing checkpoint, inference can load its weights and embedded config directly. For example:

```sh
./llm/pinyin_to_text/scripts/infer.sh --checkpoint llm/pinyin_to_text/runs/0.4b-static-csv-rngfix-v1/best.pt --input nihao
```

There is no automatic conversion of old weights into the smaller architecture or migration of old optimizer state. Older generated datasets/seeds/importers remain retired. Do not alter checkpoint identity metadata to bypass resume checks.

Setup uses Python 3.12 with pinned PyTorch 2.6.0 and NumPy 2.2.6 in `llm/.venv`, without shell activation. It accepts `--python`, `--venv`, `--offline`, `--find-links` and `--torch-index-url`; `SI_LLM_VENV` selects the environment and `SI_LLM_PYTHON` overrides the interpreter. CUDA installation is not hardware-verified. Training dependencies are not linked into the input method. Preserve PyTorch's BSD-style and NumPy's BSD notices on redistribution; SI retains GPLv3 and corpus-specific provenance. No private app vocabulary, personal phrases, history, documents or clipboard content is a source.

`make -C llm/pinyin_to_text` exposes the same separate targets (`data`/`prepare`, `run`/`train`, `resume`, `validation`/`evaluate`, `test`, `infer`/`predict`, `export`, `size`, `setup`, `check`, `smoke`). Defaults match the scripts; explicit Make variable overrides apply to that invocation. Do not mix paths across stages.
