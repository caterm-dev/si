# Small candidate-reranking baseline

An offline **7,419,392-parameter causal character language model**, initialized
from scratch. It learns next-token prediction on public text, then scores exact
candidate strings supplied by a decoder. Decoder-generated hard-negative/listwise
fine-tuning and quantization remain future work. An experimental Core ML
integration has been removed from the input method pending redesign. The separate [Pinyin-to-text model](../pinyin_to_text/README.md) generates
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

## Chat continued pretraining

The [chat preset](configs/chat.json) builds `small-chat-v2` from pinned public
data. Its target-token quotas are 9 million LCCC dialogue targets, 3.5 million
Chinese Chatbot Corpus targets, 2.5 million `dialogue` targets, 4 million Chinese
mC4 targets and 1 million Chinese MDN targets. The first three sources together
account for 75% of planned targets. Each quota can round up by one complete
utterance or document. LCCC starts after record 439,755, the last conversation
reached by the original selection. The reader keeps individual utterances,
including those with only two or three Han characters.

The local [corpus extracts](../../corpus/README.md) supply ChatterBot, PTT,
subtitles and Xiaohuangji from Chinese Chatbot Corpus, and KdConv, CrossWOZ and
Chinese OASST1 from `dialogue`. Existing upstream splits are retained. The local
Douban extract contains only its upstream test split. The separate LCCC archive
supplies LCCC once. Data preparation verifies both extracts and copies their
source manifests and attribution into the training bundle. Some Chinese
Chatbot Corpus subcorpora have unresolved redistribution terms. See
[source provenance](../../corpus/chinese/metadata/chinese-chatbot-corpus.md).

A normalized exact document already seen by the parent dataset can only be
retained in its original split. Paraphrases or partial overlap remain possible.

Run these stages from the repository root. The commands require the pinned
local archives, the verified extracts under `corpus/chinese/prepared/si-corpus/`,
the prepared `small-character-v1` dataset and its
`runs/small-character-v1/best.pt`.

```sh
./llm/reranker_small/scripts/chat.sh prepare
./llm/reranker_small/scripts/chat.sh train
# After an interruption, resume the new run:
./llm/reranker_small/scripts/chat.sh resume
```

If `data/prepared/small-chat-v2/` already exists, start with `train`. The
prepared bundle is immutable. The MPS preset uses the parent tokenizer and
loads compatible weights into a fresh AdamW run. Its learning rate peaks at
`5e-5`, and its budget is 20 million targets or 8,200 updates, whichever comes
first. The new checkpoint records the parent checkpoint hash, step and dataset
ID. `last.pt` resumes the new optimizer and data cursor, and `best.pt` follows
validation loss. The new files are under `runs/small-chat-v2/`. Pass
`--device cpu` to both training commands when MPS is unavailable.

For a fixed-pool smoke comparison, score the original and adapted checkpoints
on the [24 authored chat contrasts](benchmarks/chat-dev.jsonl). The cases
exercise everyday and work chat, short replies and homophones. This is a
development fixture with hand-supplied candidates.

```sh
small=llm/reranker_small
mkdir -p "$small/reports/small-chat-v2"
comparison="$(mktemp -d "$small/reports/small-chat-v2/comparison.XXXXXX")"
for experiment in small-character-v1 small-chat-v2; do
  "$small/scripts/evaluate.sh" --checkpoint "$PWD/$small/runs/$experiment/best.pt" \
    --benchmark "$PWD/$small/benchmarks/chat-dev.jsonl" \
    --provenance "$PWD/$small/benchmarks/chat-dev.provenance.json" \
    --device cpu --output "$PWD/$comparison/$experiment.json"
done
```

## Continue from chat v2 on unused public chat

The [unused-chat preset](configs/chat-unused.json) scans all eligible records in
the pinned LCCC-base training archive and the existing Chinese Chatbot Corpus
and `dialogue` extracts. It has no source token quotas or character caps. It
initializes a separate `small-chat-unused-v3` run from `small-chat-v2/best.pt`
and reuses its tokenizer. It does not select the local SI TXT collection, web
articles or technical documentation.

```sh
./llm/reranker_small/scripts/chat-unused.sh prepare
./llm/reranker_small/scripts/chat-unused.sh train
# Resume after an interruption, retaining the current cumulative token budget:
./llm/reranker_small/scripts/chat-unused.sh resume
```

Each command performs only its named stage. Preparation requires the existing
verified extracts under `corpus/chinese/prepared/si-corpus/`, both old prepared
bundles and the pinned raw LCCC archive; it does not download. Use the common
`SI_RERANKER_SMALL_*` overrides or explicit preparation arguments for other
paths. Existing output directories are refused rather than overwritten.

Preparation excludes exact normalized documents, whole source/conversation
groups and exact normalized paragraphs of at least 32 characters found in
**any split of either v1 or v2**. A fresh utterance in a previously selected
conversation is conservatively excluded with its group. This uses the complete
prepared histories, including documents that an early checkpoint might not
have reached. Original upstream splits remain intact. Within the new bundle,
exact-document deduplication and cross-split long-paragraph exclusion also apply.
Source and subsource token totals and exclusion counts are in the new manifest.
This is mechanical overlap filtering, not human quality certification;
paraphrases and template variants can remain.

The first training stage stops at approximately **20 million cumulative target
tokens**, checked after an update, or at the end of one data pass. The learning
rate peaks at `2e-5`; warmup/cosine schedule length and the one-pass update limit
are derived from the actual training-window count. The final update can have
fewer microbatches, so it never starts a second pass. The config's million-step
ceiling is reduced to that derived limit. Start logs show the effective update
limit and full dataset target count.

Evaluate a stage on the development ranking fixtures before extending it. To
continue the same shuffled pass with the same optimizer, RNG and cursor:

```sh
# Raise the cumulative budget to 40 million, not 40 million additional tokens:
./llm/reranker_small/scripts/chat-unused.sh resume --max-tokens 40000000
# Alternatively, finish the remaining first pass without a token cap:
./llm/reranker_small/scripts/chat-unused.sh resume --max-tokens 0
```

The complete first pass is a hard limit even when increasing `--max-steps`.
`best.pt` still follows corpus validation loss; ranking quality requires the
separate candidate evaluation below. Keep final test suites held out from stage
selection. Formal training starts only when `train` is explicitly executed.

## Continue from chat v2 on the local SI collection

The `si` stage reads every conversation in the verified
`corpus/chinese/prepared/si-corpus/si/` extract. This snapshot comes from the
TXT files recursively under `corpus/chinese/raw/si/`. Python generators and
CSV word lists enter through their generated TXT output. Normalized exact
documents are deduplicated. Conversations stay together when assigning splits,
and windows stay within a conversation. Exact split boundaries from both
`small-chat-v2` and its original `small-character-v1` ancestor are checked.

```sh
# After changing raw TXT files, first extract into a fresh corpus version:
corpus/.venv/bin/python corpus/prepare_raw_text.py --source si \
  --output corpus/chinese/prepared/si-next
./llm/reranker_small/scripts/si.sh prepare \
  --prepared-root corpus/chinese/prepared/si-next
./llm/reranker_small/scripts/si.sh train
./llm/reranker_small/scripts/si.sh resume
```

The default training bundle and run are `small-si-v3`. Preparation and training
are separate stages. When its prepared bundle already exists, start with
`train`. The new run initializes weights from `small-chat-v2/best.pt` and
reuses its tokenizer. Optimizer, learning-rate schedule and run counters start
fresh. The [SI configuration](configs/si.json) records the selected training
budget.

The local collection includes long files generated by repeating dialogue
templates with word substitutions. Related templates can occur in different
splits. Validation loss measures fit to the selected corpus and cannot establish
general input-method ranking quality. The supplied local source manifest is
preserved as provenance, and it does not assign redistribution rights.

## Evaluate a checkpoint

Use the [conversion evaluation suites](../../eval/README.md) for fixed-pool
candidate accuracy. The contextual suite has 458 queries in 229 paired
contrasts, and the context-free suite has 531 queries. Compare Top-1, MRR,
both-correct context pairs, and per-category results on identical candidate
pools. Evaluate the decoder separately with its 1,020-query recall suite.

```sh
python3 scripts/evaluate_conversion.py check
evaluation="$(mktemp -d /private/tmp/si-ranking-eval.XXXXXX)"
llm/.venv/bin/python -m llm.export_rust reranker \
  --checkpoint llm/reranker_small/runs/small-si-v3/best.pt \
  --output "$evaluation/model"
python3 scripts/evaluate_conversion.py ranking --model "$evaluation/model" \
  --output "$evaluation/ranking.json"
```

The exporter and evaluator use local files and the existing
`target/release/si-neural` binary. Repeat with `small-chat-v2/best.pt` for the
parent comparison. Fix model and scoring choices before running these tests.
The suites are authored synthetic fixtures with broader training overlap and
independent human review still unverified.

Token-loss evaluation remains available for the model's own prepared dataset:

```sh
evaluation="$(mktemp -d /private/tmp/si-token-eval.XXXXXX)"
llm/.venv/bin/python -m llm.reranker_small.evaluate \
  --checkpoint llm/reranker_small/runs/small-si-v3/best.pt \
  --data llm/reranker_small/data/prepared/small-si-v3 --split test \
  --output "$evaluation/test.json" --device mps
```

Loss and perplexity measure next-token prediction. Reports contain offline
model measurements; host-app responsiveness requires the input-method checks
in [the testing guide](../../docs/TESTING.md).

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

The [root ranking dataset](../../eval/README.md) contains query-only engine
regressions. The commands below run token-loss evaluation, score a supplied
candidate pool or export the model for offline inference.

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
This benchmark protocol is offline; the input method does not load this model.

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
weight license. Training data, runs, reports and experimental exports are
ignored by Git. The selected Rust inference export and its source notices
are tracked in [Data/RerankerSmall](../../Data/RerankerSmall/README.md).
The [large reranker](../reranker_large/README.md) remains a separate planned model.

## Offline inference

The earlier Core ML integration and `scripts/stage_app.sh` are retired.
`coreml_export` still supports standalone research exports. The
[fixed-pool ranking suite](../../eval/README.md#ranking)
evaluates the Rust character scorer on authored candidate lists.

The local Core ML smoke-test bundle was removed. The [Rust inference prototype](../README.md#rust-inference-prototype)
uses an independent export of the existing checkpoint.
