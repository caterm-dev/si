# Small candidate-reranking baseline

An offline **7,419,392-parameter causal character language model**, initialized
from scratch. It learns next-token prediction on public text, then scores exact
candidate strings supplied by a decoder. Decoder-generated hard-negative/listwise
fine-tuning and quantization remain future work. An experimental Core ML
comparison and bounded native scheduling are implemented separately below. The separate [Pinyin-to-text model](../pinyin_to_text/README.md) generates
conversions; this model only scores supplied text.

## Terminal quick start

Run from the repository root. Scripts also work from another directory when
addressed with absolute paths. Each command performs one stage.

```sh
cd /Users/eric/src/si
./llm/reranker_small/scripts/setup.sh
./llm/reranker_small/scripts/check.sh
./llm/reranker_small/scripts/smoke.sh
./llm/reranker_small/scripts/data.sh
./llm/reranker_small/scripts/run.sh
```

Replace the example checkout path as needed. Setup only installs dependencies;
check/smoke use tiny synthetic models. **Only `run.sh` starts the formal baseline.**
Preparation never downloads; raw sources are
acquired independently through the [corpus workspace](../../corpus/README.md).

Setup uses shared `llm/.venv`, Python 3.12, Torch 2.6.0, NumPy 2.2.6 and OpenCC
0.1.7. It accepts `--python`, `--venv`, `--offline` and repeatable `--find-links`.
Existing non-venv directories are refused. Nothing is installed into the app.

## Model and experiment presets

See [configs/small.json](configs/small.json) and
[scripts/defaults.sh](scripts/defaults.sh).

| Item | Initial value |
| --- | --- |
| Model | Four pre-norm blocks, width 256, four heads, GELU FFN 1,024, tied embeddings |
| Vocabulary / context | 16,384 / 256 tokens; learned positions; dropout 0.1 |
| FP32 weights only | 29,677,568 bytes; excludes runtime memory and metadata |
| Experiment | `small-character-v1` |
| Dataset | `llm/reranker_small/data/prepared/small-character-v1/` |
| Run/checkpoints | `llm/reranker_small/runs/small-character-v1/` |
| Reports | `llm/reranker_small/reports/small-character-v1/` |
| Export | `llm/reranker_small/exports/small-character-v1/` |
| Device / threads | MPS / 4; CPU selectable; CUDA is not hardware-verified here |
| Optimizer | AdamW, LR `3e-4`, betas `(0.9, 0.95)`, weight decay `0.1`, clip `1.0` |
| Schedule | 300 warmup steps, cosine decay to 10% of peak over 10,000 steps |
| Batch | Eight windows × 16 accumulation steps; FP32, no activation checkpointing |
| Budget | 10,000 updates or 200 million target-token exposures, whichever is first |

Updates use the actual nonpadding-token mean across accumulated microbatches.
There are at most 32,768 targets per update, often fewer for short documents.
Logs report actual `step_tokens` and `tokens_seen`; the token budget is checked
after completed updates and may overshoot by one update. These are experiment
budgets, not accuracy or latency guarantees.

Scripts need no environment activation. Full `SI_RERANKER_SMALL_`-prefixed
overrides are available for `EXPERIMENT`, `CONFIG`, `DATA`, `RUN`, `REPORT_ROOT`,
`CHECKPOINT`, `EXPORT`, `DEVICE`, `THREADS`, `PYTHON` and `VENV`. Converter
`SI_LLM_*` overrides do not affect this family. Explicit CLI arguments win.
For CPU, set `SI_RERANKER_SMALL_DEVICE=cpu` consistently across stages.

## Whole-document preparation

The default reads all six existing pinned raw source types, with a soft limit
of **20 million retained text characters per source**, checked after each whole
document. A source may exceed the budget by one document. Smaller sources are
exhausted. This selects a deterministic archive prefix, not all available raw
data or a representative random sample. Set `data.max_characters_per_source=0`
and choose a fresh dataset path to process the entire pinned subset. Documents
above two million characters are counted and excluded rather than clipped.

Preparation reuses the corpus raw readers, not the existing 4–96-Han fragment
files. It retains cleaned articles/turns, titles where supplied, punctuation,
paragraph breaks, English word spaces and digits. OpenCC `t2s` only affects the
derived text. Original archives and earlier datasets remain untouched.

Seeded source/group hashes assign 97% train, 2% validation and 1% test in
expectation; actual counts are recorded. Wikipedia revisions group by page;
LCCC turns group by conversation. Normalized whole documents are deduplicated.
A later document sharing an exact normalized paragraph of at least 32 characters
with another split is excluded in full, never moved or cut into another split.
Short common strings, paraphrases and semantic duplicates can still overlap.

The vocabulary fits **training text only**. Unknown Unicode uses lossless UTF-8
byte fallback; encoding coverage does not establish learned rare-character usage.
Each 256-token window stays inside one document. Targets cover that document
once per pass, including EOS, with no continuation into another document.

Prepared bundles contain `manifest.json`, `tokenizer.json`,
`{split}.documents.jsonl` (whole text/origin/group, with JSON-escaped paragraphs),
uint16 little-endian `{split}.tokens.bin`, uint64 `(offset,length)`
`{split}.windows.bin`, source locks and actual selected-source notices/licenses.
Outputs are staged immutably and refuse existing destinations. `--source-lock`
and `--raw-root` select explicit archive locations. No personal phrases, app
vocabulary, clipboard, typing history or unrelated private documents are read.

## Training, interruption and resume

Every 500 updates and at the budget boundary, training evaluates up to 262,144
validation targets from a fixed seed-zero window permutation, sampling across
the bundle rather than only its first source. `best.pt` follows that token loss. `last.pt` includes
optimizer, RNG and cursor state; a step-zero checkpoint is saved too. Metrics
contain numeric progress, not corpus text. Training never opens test token files.

Control+C stops the foreground process. Resume starts from the last completed
saved update; unsaved updates may be repeated:

```sh
./llm/reranker_small/scripts/resume.sh
# Extend reached budgets if needed; preserve the original LR schedule:
./llm/reranker_small/scripts/resume.sh --max-steps 20000 --max-tokens 400000000
```

Resume requires unchanged code, data, tokenizer, config except budgets, device,
threads and PyTorch. CPU/accelerator RNG states, including dropout, are restored.
CPU resume is tested bitwise against continuous training. MPS repeated fresh
runs have small floating-point differences too; MPS resume/repeat are checked
with `atol=1e-6, rtol=1e-5` and exact RNG/cursor checks, not bitwise weight equality.
Changing `schedule_steps`, model shape or optimizer requires a new run. Choose
`SI_RERANKER_SMALL_EXPERIMENT=small-character-v2` for another experiment and keep
its stage paths consistent. Existing conversion checkpoints cannot resume here.

## Explicit evaluation, scoring and export

The [Chinese ranking challenge](benchmarks/README.md) adds 1,230 cases from 337
anchors, with family-separated development/test splits, real SICore candidate
pools and a pinned overlap audit. Run it after training:

```sh
./llm/reranker_small/scripts/evaluate_suite.sh
```

Use its development split for tuning; its AI-assisted labels and correlated
variants are not an independently human-annotated production benchmark.

```sh
./llm/reranker_small/scripts/validation.sh
./llm/reranker_small/scripts/test.sh

./llm/reranker_small/scripts/rank.sh --context '今天下午，' \
  --candidate '我们开会' --candidate '我们开慧' --input womenkaihui

./llm/reranker_small/scripts/evaluate.sh \
  --benchmark llm/reranker_small/benchmarks/example.jsonl \
  --provenance llm/reranker_small/benchmarks/example.provenance.json

./llm/reranker_small/scripts/export.sh
```

Standalone validation/test evaluate their full split; `--max-tokens N` explicitly
requests a partial report. These are next-token loss/perplexity reports, **not
candidate accuracy**. Repeated reports/exports require `--output NEW_PATH`.

Candidate scores sum only candidate-token log probabilities, beginning with the
first token predicted from the final context position. Context probability and
a hypothetical candidate EOS are excluded. All candidates share the same context
suffix, trimmed at Unicode scalar/byte-fallback boundaries. Ties retain original
order; strings are never normalized or generated. A pool containing a candidate
too long for the context abstains and preserves its original order. Optional
length penalty defaults to zero and needs validation. Explicit input spelling is
retained as a separate final literal choice; empty input yields no choices.

The initial scoring pool must already contain complete aligned Chinese candidates
from a decoder. Pinyin validation, prefix/whole comparison, mixed-language score
calibration and integration with SI dictionary scores remain separate work.
The native comparison below can load an explicitly converted local model; this offline benchmark protocol remains separate from the independent UI ranking.

Benchmark JSONL contains `id`, optional `context`, `candidates`, and `references`
(accepted exact strings), with a separate origin/license/revision declaration.
Reports include top-1, MRR, candidate recall ceiling, original-order accuracy,
correct-to-wrong changes, abstentions and synchronized offline p50/p95 timing.
Missing gold candidates are recall failures. The three checked-in examples are
synthetic workflow fixtures; neither they nor declaration metadata prove model
quality or absence of training overlap. Use a fixed independent real-error set
before selecting models. Timing includes the first/cold case and is not host latency.

Exports contain FP32 weights, tokenizer, hashes and actual selected-source
attribution, without optimizer/RNG. Loading needs no original corpus. Export
requires the prepared dataset to verify provenance and assigns no blanket model
weight license. Data, runs, reports, exports and weights are ignored by Git.
The [large reranker](../reranker_large/README.md) remains a separate planned model.

## Native app comparison

The app can compare unchanged engine ranking with local AI ranking in two collapsed
rows. This first version uses **empty preceding context**, the same lossless scalar
and byte tokenizer, FP32 Core ML CPU inference, and batches of four. It scores at
most 32 eligible complete candidates. Prefixes remain unscored;
prefix/whole model calibration remains separate work.
The AI row sorts by weighted mean log probability in bits per Unicode scalar,
independently of engine scores. Personal pins/corrections retain priority; model ties
use original order, and unscored paths follow in original relative order. Scores
are unclamped. Settings weight defaults to 1 (range 0–2); positive values only scale
scores, while 0 restores original ordering. The raw `rank.sh` command still returns
summed log probabilities, rather than normalized UI scores.
The heuristic, pool limit and empty context differ from the constructed benchmark;
that benchmark's accuracy cannot be claimed as App quality.

Install conversion-only tooling into an ignored directory, preserving the pinned
training environment. From the repository root:

```sh
./llm/.venv/bin/python -m pip install --no-deps --target .build/coreml-tools \
  -r llm/reranker_small/requirements-coreml.txt
./llm/reranker_small/scripts/stage_app.sh
./scripts/test.sh
./scripts/build.sh
```

Staging uses `best.pt` by default and accepts the existing checkpoint/data environment
overrides or explicit CLI flags. It verifies dataset/source provenance, converts
with coremltools 8.3.0 and macOS 14 deployment, validates short/full-context/byte-fallback
predictions against Python, compiles with `xcrun coremlcompiler`, then copies artifacts
to ignored `mac/SI/Core/Resources/Reranker/`. It refuses an existing staged model;
use `--output NEW_DIRECTORY` to inspect another conversion before explicitly replacing
local staged artifacts. The stage reads only public model/corpus artifacts, never
live personal data. `runtime.json` records checkpoint/tokenizer identity and numerical
validation; the manifest and copied notices retain source attribution without assigning
a blanket license to model weights. Review redistribution terms before publishing.

Coremltools warns that Torch 2.6.0 is newer than its tested 2.5.0 converter support;
conversion is therefore accepted only after numerical validation. FP32 Core ML and
PyTorch need not be bitwise equal. The exporter checks `atol=0.005, rtol=0.0001`,
including the 256-token boundary, and native tests compare short reference scores.
Normal builds require no Python or model download. A missing model displays an
unavailable state and retains base input. Generated model artifacts are deliberately
not in Git; a fresh checkout must stage them explicitly to exercise AI.

The comparison does not collect history or train online. Native tests cover real
engine-to-model scoring, two-row rendering and exact commits; live InputMethodKit,
host-focus and VoiceOver checks remain separate in `docs/TESTING.md`.
