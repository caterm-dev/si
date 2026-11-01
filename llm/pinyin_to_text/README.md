# SI Pinyin character and word training

This guide covers the converter in the [model workspace](../README.md).
The sibling small/large reranker directories are separate planned model families.
Python dependencies and the existing environment remain shared at `llm/requirements.txt`
and `llm/.venv`; all converter-specific files and artifacts live here.

The default experiment trains a randomly initialized **19,711,488-parameter encoder-decoder** on explicit Pinyin-to-Han character/word pairs. It is separate from the macOS input method; no neural model is loaded by SI. Conversion quality and native deployment remain unproven.

## Active data

Edit [data/pinyin-csv/](data/pinyin-csv/README.md). Each split has two files:

```text
data/pinyin-csv/
  provenance.json
  selection.json
  train/characters.csv
  train/words.csv
  validation/characters.csv
  validation/words.csv
  test/characters.csv
  test/words.csv
```

```csv
input,target
ni,你
hao,好
nihao,你好
beijing,北京
shurufa,输入法
```

Keep one-Han outputs in `characters.csv` and two/three-Han lexical entries in `words.csv`. Inputs are continuous lowercase toneless Pinyin. The initial collection contains **2,021 training pairs** (937 character/readings, 1,084 words), **73 validation** and **69 test** pairs. Counts are pairs, not unique characters. Multiple targets for one Pinyin spelling are intentional; evaluation groups them as accepted alternatives.

The collection selects earlier SI-authored vocabulary and derives additional character pairs once from training words, checking unique syllable alignment against the existing SI inventory. Preparation never generates examples, Pinyin, typos or split assignments. See the data guide and selection audit for source hashes and limitations. Validation/test retain their original split assignments, with no cross-split identical input or output. Their contents must not be added to training for memorization.

This experiment excludes chat sentences, English/mixed text and typo sources. `womenzaijia -> 我们在家` and learned English/correction behavior are outside its training scope. It contains only a limited vocabulary; 22/73 validation and 19/69 test pairs initially contain a Han character absent from training outputs. They remain explicit coverage failures, not silently removed cases. Known-character word composition and unseen-character coverage must be distinguished when interpreting results. UTF-8 fallback preserves encodings but does not teach unseen character outputs.

The earlier 50,000-pair collection remains unchanged in [data/csv/](data/csv/README.md), along with old prepared snapshots and checkpoints. It is no longer the default source.

## Separate preset commands

Each script performs one task. Run these separately from any working directory:

| Command from repository root | Task |
| --- | --- |
| `./llm/pinyin_to_text/scripts/setup.sh` | Prepare the isolated Python environment |
| `./llm/pinyin_to_text/scripts/data.sh` | Freeze the active CSV data (`prepare.sh` alias) |
| `./llm/pinyin_to_text/scripts/run.sh` | Start a new small-model run (`train.sh` alias) |
| `./llm/pinyin_to_text/scripts/resume.sh --max-steps 3000` | Extend the same unchanged run to a total step count |
| `./llm/pinyin_to_text/scripts/validation.sh` | Evaluate the complete validation split |
| `./llm/pinyin_to_text/scripts/test.sh` | Evaluate the complete test split after model selection |
| `./llm/pinyin_to_text/scripts/infer.sh --input nihao` | Inspect one input; default is `nihao` |
| `./llm/pinyin_to_text/scripts/export.sh` | Export inference weights from `best.pt` |
| `./llm/pinyin_to_text/scripts/size.sh` | Count parameters without allocating model weights |
| `./llm/pinyin_to_text/scripts/check.sh` | Run framework regressions using tiny fixtures |
| `./llm/pinyin_to_text/scripts/smoke.sh` | Run a four-step tiny CPU workflow check |

No ordinary stage automatically invokes setup or the next stage. Training retains periodic validation loss and checkpoints; separate candidate validation/test require explicit commands. Smoke is an explicit development check using a tiny model, not the configured 19.7M model.

[defaults.sh](scripts/defaults.sh) now selects:

| Preset | Location/value |
| --- | --- |
| Model | `llm/pinyin_to_text/configs/small-pinyin.json` |
| CSV source | `llm/pinyin_to_text/data/pinyin-csv/` |
| Prepared bundle | `llm/pinyin_to_text/data/prepared/pinyin-lexical-v1/` |
| Run | `llm/pinyin_to_text/runs/small-pinyin-lexical-v1/` |
| Reports | `llm/pinyin_to_text/reports/small-pinyin-lexical-v1/{validation,test}.json` |
| Device / threads | MPS / 4 |

Old `SI_LLM_*` environment overrides still take precedence. Use a fresh terminal, or unset old experiment/config/data/run/CSV/report/checkpoint overrides before using the new presets. Keep a terminal's chosen experiment consistent across stages. Relative paths resolve from the repository root.

Preparation and fresh training refuse existing output directories. Edit the experiment name in `defaults.sh`, or set `SI_LLM_EXPERIMENT=pinyin-lexical-v2`, to use matching new data/run/report paths after CSV edits. Do not replace an existing run's bundle. `SI_LLM_CONFIG`, `SI_LLM_CSV_ROOT`, `SI_LLM_DATA`, `SI_LLM_RUN`, `SI_LLM_REPORT_ROOT`, `SI_LLM_CHECKPOINT`, `SI_LLM_DEVICE` and `SI_LLM_THREADS` override individual defaults; explicit CLI arguments override those presets.

## Model and training budget

[small-pinyin.json](configs/small-pinyin.json) uses four encoder and four decoder layers, width 384, eight attention heads, feed-forward width 1,536 and vocabulary capacity 8,192. Source/target limits are 48/16 tokens, with no truncation. The model retains sinusoidal positions, pre-normalization, shared embedding/output weights, causal decoding and literal fallback. It does not add spelling-constrained decoding or a copy branch.

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
./llm/pinyin_to_text/scripts/validation.sh --output llm/pinyin_to_text/reports/small-pinyin-lexical-v1/validation-step1000.json
```

`--limit N` explicitly marks a partial report. An external benchmark can be supplied with `--benchmark PATH` containing provenance and the selected split's CSVs; its inputs/targets must not overlap that model's train/validation. `compare.sh` requires matching dataset/split/cases/k. Offline p50/p95 timings are not host-app latency claims. The small workflow checks and bounded memorization probes do not establish held-out conversion accuracy.

## Previous experiments and dependencies

[0.4b-static-csv.json](configs/0.4b-static-csv.json), the earlier [50,000-pair CSVs](data/csv/README.md) and existing run/data/report directories remain available for explicit use. To evaluate an old model, pass its checkpoint and its matching prepared bundle; changing only `--output` does not select a different model. Inference can load old weights from their embedded config, for example:

```sh
./llm/pinyin_to_text/scripts/infer.sh --checkpoint llm/pinyin_to_text/runs/0.4b-static-csv-rngfix-v1/best.pt --input nihao
```

There is no automatic conversion of old weights into the smaller architecture or migration of old optimizer state. Older generated datasets/seeds/importers remain retired. Do not alter checkpoint identity metadata to bypass resume checks.

Setup uses Python 3.12 with pinned PyTorch 2.6.0 and NumPy 2.2.6 in `llm/.venv`, without shell activation. It accepts `--python`, `--venv`, `--offline`, `--find-links` and `--torch-index-url`; `SI_LLM_VENV` selects the environment and `SI_LLM_PYTHON` overrides the interpreter. CUDA installation is not hardware-verified. Training dependencies are not linked into the input method. Preserve PyTorch's BSD-style and NumPy's BSD notices on redistribution; SI retains GPLv3 and corpus-specific provenance. No private app vocabulary, personal phrases, history, documents or clipboard content is a source.

`make -C llm/pinyin_to_text` exposes the same separate targets (`data`/`prepare`, `run`/`train`, `resume`, `validation`/`evaluate`, `test`, `infer`/`predict`, `export`, `size`, `setup`, `check`, `smoke`). Defaults match the scripts; explicit Make variable overrides apply to that invocation. Do not mix paths across stages.
