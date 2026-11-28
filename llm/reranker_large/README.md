# 15.6M character student and Qwen distillation

This directory contains an offline candidate-reranking framework. The student
uses **15,592,320 parameters**: seven pre-norm causal Transformer blocks,
width 384, six 64-dimensional attention heads, GELU FFN 1,536, an 8,192-entry
character/byte vocabulary, learned absolute positions for 64 tokens, tied
input/output embeddings and initial dropout 0.1. FP32 weights alone occupy
62,369,280 bytes; FP16 storage arithmetic is 31,184,640 bytes. Runtime memory
and latency require measurement.

The implementation reuses `reranker_small`'s model, tokenizer, verified LM
windows and checkpoint loader, and the shared Rust exporter. Existing small
model code, checkpoints and historical reports are retained. This directory
has independent configuration, code identities, runs and command defaults.
`large` describes the comparison with the packaged 7.4M scorer; it does not
mean the Qwen teacher is deployed, or that pause-time scheduling exists.

**Status:** configuration, raw-text-v2 source adaptation/sampling, explicit preparation, pretraining, local Qwen
scoring, candidate-level distillation, strict resume, evaluation and export
are implemented. Tiny CPU regressions use authored synthetic documents and a
synthetic teacher. No formal corpus selection/preparation, bulk Qwen scoring,
15.6M training, production-quality evidence or app replacement is supplied by
these checks. The app defaults to Small and can select the FP16 weight edit in
`Data/RerankerLarge/`. Reproduce that bundle from the verified local export
using a fresh output directory:

```sh
llm/.venv/bin/python llm/reranker_large/scripts/package_large_fp16.py \
  llm/reranker_large/exports/weight-edit-v1 /tmp/SI-RerankerLarge
```

A full-size random-initialization export/parity regression also checks the
selected architecture without training it.

## Independent stages

Run from the repository root; shell scripts also work from another directory.
Every stage is explicit. No ordinary stage installs dependencies, downloads
models, reads live input/history, prepares a later stage or starts another run.
Smoke intentionally chains tiny synthetic stages in a temporary directory.

| Command | Purpose |
| --- | --- |
| `scripts/setup.sh` | Explicit installation of pinned student dependencies |
| `scripts/setup.sh --teacher` | Also install pinned Transformers/Qwen dependencies |
| `scripts/size.sh` | Count the configured model without allocating real weights |
| `scripts/prepare-data.sh` | Verify and sample existing raw-text-v2 snapshots, then encode a ready LM bundle |
| `scripts/prepare-distillation.sh` | Freeze SI metadata or generate bounded candidate pools with case-distribution reports |
| `scripts/data.sh` | Freeze explicitly supplied reviewed documents and a train-only vocabulary |
| `scripts/pools.sh` | Validate explicit candidate records against those source documents |
| `scripts/teacher.sh` | Score train/validation pools with an existing local Qwen snapshot |
| `scripts/pretrain.sh` | Start a new randomly initialized student LM run |
| `scripts/distill.sh` | Initialize a separate distillation run from a compatible pretrained student |
| `scripts/distill-pilot.sh` | Use the selected continued-step-019167 archive and existing Qwen pilot cache for 1,000 updates |
| `scripts/prepare-app-teacher.sh` | Export native App statistical scores/model masks and supplement Qwen conditional/BOS likelihoods |
| `scripts/distill-app.sh` | Retrain from continued-step-019167 with the matched App score/fusion protocol |
| `scripts/resume.sh --stage pretrain` | Resume the unchanged pretraining run |
| `scripts/resume.sh --stage distill` | Resume the unchanged distillation run |
| `scripts/validation.sh`, `scripts/test.sh` | Explicit held-out LM token-loss evaluation |
| `scripts/evaluate.sh` | Supplied-pool ranking/reference/teacher-agreement evaluation |
| `scripts/rank.sh` | Inspect bounded scores for supplied candidates |
| `scripts/export.sh` | Export Python and Rust inference weights with provenance |
| `scripts/benchmark.sh` | Check Rust/Python parity and time warmed resident Rust CLI requests |
| `scripts/check.sh` | Synthetic regressions, including exact CPU resume in both phases |
| `scripts/smoke.sh` | Tiny CPU workflow with a synthetic teacher; temporary outputs are removed |

Use `--help` on each script for arguments, or `make -C llm/reranker_large help`.
Setup defaults to Python 3.12 and the existing `llm/.venv`. An alternative
environment can be selected with `--venv`. `--offline` and `--find-links` are
available for installation. Setup downloads Python packages only when explicitly
invoked; it never downloads Qwen or corpora. Teacher dependencies are optional
for student training on an already frozen cache.

The optional teacher pins are Transformers 4.51.3, safetensors 0.5.3,
huggingface-hub 0.31.2 and tokenizers 0.21.1. Their upstream projects declare
Apache-2.0: [Transformers](https://github.com/huggingface/transformers),
[safetensors](https://github.com/huggingface/safetensors),
[huggingface_hub](https://github.com/huggingface/huggingface_hub) and
[tokenizers](https://github.com/huggingface/tokenizers). They are offline
training/scoring tools, not macOS app dependencies. This does not relicense
the source corpora or teacher outputs.

## Paths and configuration

`configs/pretrain.json` and `configs/distill.json` select the same architecture.
The first pretraining budget is 15,000 steps or 200 million target-token
exposures, with AdamW, learning rate `3e-4`, batch 16 and accumulation 8.
Distillation starts at `5e-5`, batch 4 and accumulation 4, capped at 10,000
steps. These are editable experiment starting points, not trained settings or
accuracy promises. New configurations/data need new experiment directories.

The default experiment is `student-15m-v1`:

```text
configs/                      Maintained pretrain, distill and tiny smoke configurations
data/prepared/<name>/lm/       Frozen documents, tokenizer and LM windows
data/prepared/<name>/pools/    Source-linked candidate pools without teacher scores
data/prepared/<name>/teacher/  Immutable teacher cache
runs/<name>/pretrain/          Independent best.pt, last.pt, identity and metrics
runs/<name>/distill/           Independent initialized/distilled checkpoints
reports/<name>/               Evaluation/parity reports
exports/<name>/               model.pt, rust/ and selected provenance
```

Prepared data, caches, checkpoints, reports and exports are ignored by Git.
Fresh outputs refuse existing directories/reports. `SI_RERANKER_LARGE_EXPERIMENT`
selects a different experiment. Individual overrides are `PRETRAIN_CONFIG`,
`DISTILL_CONFIG`, `DATA`, `POOLS`, `TEACHER_DATA`, `RUN_ROOT`, `REPORT_ROOT`,
`CHECKPOINT`, `EXPORT`, `VENV`, `PYTHON` and `TEACHER_PYTHON`, all prefixed with
`SI_RERANKER_LARGE_`. Teacher Python may point at a separate compatible local
inference environment. Explicit CLI flags override path defaults. Scripts
resolve relative paths from the repository root.

## Document input contract

The first pretraining mixture targets Chinese input with occasional embedded
English. Default source targets are measured in training target tokens, not rows or bytes:

| Source group | Target share | Initial selection |
| --- | --- | --- |
| Chinese dialogue | 60% | LCCC-base, with selected KdConv/CrossWOZ conversations |
| Chinese Wikipedia | 35% | The existing pinned Chinese article snapshot |
| Technical prose | 5% | Selected Chinese Kubernetes, TensorFlow and MDN text |

The first experiment excludes standalone English corpora. Retain naturally
occurring English words, identifiers and phrases in the selected Chinese
sources, including spaces and casing. Standalone English prediction is not
the training objective for this first experiment. Report source-token shares
and mixed-text coverage separately; preserve whole documents/conversation
groups and record any deviations from the target shares.

`configs/corpus.json` fixes these target shares for the explicit
`prepare-data.sh` stage. `data.sh` remains the separate manual-JSONL entry
point. Data has not been materialized merely by installing this framework.

## Prepare existing raw-text-v2 snapshots

From the repository root, run one data-preparation command (or use the
script's absolute path from another directory):

```sh
./llm/reranker_large/scripts/prepare-data.sh
```

The script reads the existing `corpus/chinese/prepared/raw-text-v2/` snapshots
for `lccc`, `dialogue`, `wikipedia`, `kubernetes`, `tensorflow` and `mdn`.
Only KdConv and CrossWOZ are retained from `dialogue`; its duplicate LCCC-base
copy, OASST1 and other datasets are excluded. No raw archive extraction,
download, model loading or training is performed. No standalone English
corpus, local SI synthetic collection, private learning archive or input
history is read. English embedded in selected Chinese text remains intact.

`--dialogue-root` can select a different complete prepared dialogue directory,
such as `corpus/chinese/prepared/si-corpus/dialogue`. All other sources still
come from `--prepared-root`. This supports a separately prepared dialogue
snapshot that already excludes the LCCC copy. The selected directory must
contain matching `manifest.json`, `text.txt`, `documents.jsonl` and attribution
files; it receives the same full checks and its own manifest hash is recorded.
Do not delete turns from only `text.txt`: the remaining metadata line ranges
and checksums would describe different data. The sampler already excludes
`lccc-base` records when they are present, so manual deletion is unnecessary.

```sh
./llm/reranker_large/scripts/prepare-data.sh \
  --dialogue-root corpus/chinese/prepared/si-corpus/dialogue
```

Each manifest, file size, complete text/metadata SHA-256 and metadata line
range is verified. Hashes cover excluded rows too. Retained source notices
are read from `corpus/chinese/` for pinned sources and the prepared dialogue
snapshot's `attribution/` files for KdConv/CrossWOZ. These small attribution
files are required even though raw archives are not. Input manifest hashes,
source notices, revisions and preparation settings accompany the output.

LCCC turns are grouped by original row; KdConv/CrossWOZ by original
dataset/file/conversation, with ascending original turns. Turn text is joined
using the snapshot's existing line breaks, without invented speaker labels.
Wikipedia remains grouped by page and technical text by source page. Exact
normalized duplicates retain a held-out copy in preference to a training
copy; no upstream split is reassigned. Sources without explicit splits get
deterministic 97%/2%/1% group-hash partitions. Supplied validation/test splits
are preserved. Selected exact paragraphs of at least 32 normalized characters
cannot cross splits; a conflicting whole group is excluded. Semantic/template
leakage beyond these checks remains unverified.

The default training quota is **100 million target tokens**, with additional
validation/test budgets proportional to 2/97 and 1/97. Groups are sampled in
seeded hash order, not from a source prefix. A bounded train-only calibration
sample fits a provisional tokenizer for quota estimates; whole groups are
retained, so the last group may exceed a quota. The final 8K tokenizer is
fitted again using only the selected training documents. The final measured
token shares in `sampling-report.json` are authoritative and can differ from
the quota estimates. Source counts and byte-fallback counts are also retained
per split and per source in the final manifest.

```sh
# Smaller target, still validating/scanning the complete selected snapshots:
./llm/reranker_large/scripts/prepare-data.sh --train-tokens 10000000
# Alternate local snapshots/notices and a fresh output:
./llm/reranker_large/scripts/prepare-data.sh \
  --prepared-root /path/to/raw-text-v2 \
  --notices-root /path/to/corpus/chinese \
  --output /path/to/fresh-lm-bundle
```

`--mixture-config` selects a different versioned sampling configuration.
An insufficient estimated source/split quota fails with counts; reduce the
target or explicitly use `--allow-shortfall` to publish the measured shortfall.
No missing quota is silently filled from another source or split. Every
final split must still contain training windows.

The default output is `data/prepared/student-15m-v1/lm/` (or the selected
experiment/DATA override), directly accepted by `pretrain.sh`. It contains
`tokenizer.json`, split token/window arrays and document JSONLs, the verified
manifest/source notices, `sampling-report.json`, and `import/` audit records
with the sampled document interchange, provenance and calibration tokenizer.
Existing outputs are refused; failed/cancelled runs remove their staged
outputs. Preparation streams input and uses disposable SQLite scratch storage
under the output parent; allow disk space for the grouped source index and
final bundle. The script reports progress counts, never source text. A smaller
token quota reduces selected output, not the complete snapshot verification
scan. No formal preparation run is performed by tests.

## Prepare an additional unused batch

Do not rerun ordinary preparation with only a new output or seed: it can
select old text again and fits another tokenizer. For another approximately
100 million **training target tokens**, run from the repository root:

```sh
./llm/reranker_large/scripts/prepare-extra-data.sh \
  --parent-data llm/reranker_large/data/prepared/student-15m-v1/lm \
  --dialogue-root corpus/chinese/prepared/si-corpus/dialogue \
  --train-tokens 100000000 \
  --allow-heldout-shortfall \
  --output llm/reranker_large/data/prepared/student-15m-extra-v1/lm
```

This separate entry point keeps the parent's exact tokenizer bytes and the
existing seed/split policy. It excludes normalized whole documents,
source/conversation/page groups, and exact normalized paragraphs of at least
32 characters from **every split** of the parent bundle. Newly selected
validation/test groups remain disjoint from training. Semantic near-duplicates
are not detected. It uses the same verified public snapshots, notices and
60% dialogue / 35% Chinese Wikipedia / 5% technical mixture, without a
standalone English corpus or personal data. No download, model execution or
training is performed.

Quotas use the frozen tokenizer, including document EOS targets;
complete groups can slightly exceed the requested counts. Additional validation
and test targets follow the configured 2/97 and 1/97 ratios. Inspect actual
counts, exclusion statistics and shares in `sampling-report.json`. Training
category quotas remain strict. The explicit `--allow-heldout-shortfall` option
retains available validation/test category text when old-data exclusions leave
a shortage; each deficit is logged and recorded as `shortfall_targets`, and
the actual held-out mixture is reported. For example, the current unused
technical test slice has 37,532 targets rather than the requested 51,546.
Without the option, held-out deficits still fail. Empty complete splits always
fail. Neither mode reuses old text, moves held-out groups into training, or
backfills a shortage from another category. Existing outputs are refused, and cancelled or
failed staging is removed. For later batches, repeat `--exclude-data` for
every additional previously prepared bundle, retaining the original
`--parent-data`.

The preparation implementation lives under `scripts/`, outside the running
trainer's hashed module set. It can prepare a separate output while the
original run continues, without changing its resume identity, arrays or
checkpoints. SQLite indexing/encoding uses CPU and disk. Full snapshot checks
and parent exclusion indexing still scan their inputs even for smaller quotas.
Keep enough space for the temporary grouped-source index and the final bundle.

The resulting bundle has the existing LM format and a new dataset identity.
Use the separate continuation command below; it is not a replacement for the
active dataset. Ordinary strict `resume.sh` still rejects changed dataset
identities. Data preparation does not start training. Synthetic verification:

```sh
llm/.venv/bin/python -m unittest llm.reranker_large.tests.test_extra_corpus
```

## Continue pretraining on the additional batch

Start from the preserved 60k model on the frozen-tokenizer additional batch:

```sh
# Read-only CPU compatibility check; creates no run and performs no updates:
./llm/reranker_large/scripts/continue-pretrain.sh --check-only
# Explicitly start a new experiment:
./llm/reranker_large/scripts/continue-pretrain.sh
```

Defaults are explicit and independent of the original experiment:

- Config: `configs/continue-pretrain.json`.
- Data: `data/prepared/student-15m-extra-v1/lm/`.
- Initial weights: `runs/student-15m-v1/snapshots/pretrain-step-060000/best.pt`.
- New run: `runs/student-15m-extra-v1/pretrain/`.

Initialization copies model weights only. AdamW, RNG/epoch ordering, step and
target-token counters start fresh; the parent checksum, step, dataset identity
and complete known dataset lineage are retained. All ancestor dataset IDs
must appear in the new bundle's explicit exclusions. Model configuration and
the complete frozen tokenizer must match. Existing runs are refused.

The initial preset uses batch 16, accumulation 8, peak learning rate `3e-5`,
100 warmup steps and cosine decay to `3e-6`. It stops after at most one pass,
deriving the schedule and step cap from actual windows; the final update may
contain fewer microbatches. The current 2,453,372-window bundle needs
**19,167 new steps** to consume its 100,000,742 training targets once. Counters
start at zero in this new experiment rather than continuing from 60,000.
Validation and saves run every 250 steps and at the end; final-test arrays are
never opened by training. Best follows this batch's validation token loss.

To resume an interrupted new experiment, use the same separate entry point:

```sh
./llm/reranker_large/scripts/continue-pretrain.sh --resume
```

`--config`, `--data`, `--run`, `--init-checkpoint`, `--device`, `--threads`,
`--max-steps` and `--max-tokens` are explicit overrides. For a shorter pilot,
start with `--max-steps 10000`, then use `--resume` to finish the same single
pass. Budgets cannot extend this entry point beyond one pass. Its strict
resume binds its own implementation plus shared code, dataset, effective
config, tokenizer, device, PyTorch and thread count. Original training modules
and their resume identities remain unchanged. Checkpoints retain the standard
pretraining format for the existing evaluation, export and distillation tools;
supply the new `--data` and `--checkpoint` when using those tools.

Synthetic verification:

```sh
llm/.venv/bin/python -m unittest llm.reranker_large.tests.test_continuation
```

## Manual document input

No corpus mixture or source rights are inferred. Corpus selection, source
review and conversion from existing [corpus bundles](../../corpus/README.md)
to the following reviewed interchange are explicit upstream work. Original
train/validation/test assignments must be preserved. Assign previously unsplit
documents by document/conversation/template family before producing records;
never split random windows or independent turns from one conversation.

Document JSONL records contain:

```json
{"source":"selected-source","origin":"document-or-turn-origin","group":"conversation-or-template-family","split":"train","text":"今天需要登录。English text remains intact."}
```

Provide all three splits. `source` plus `group` must belong to only one split;
exact normalized duplicates and exact paragraphs of at least 32 normalized
characters cannot cross splits. Exact duplicates inside a split are removed.
Text bytes remain unchanged, windows never cross documents, and only train
text fits the tokenizer. Semantic/template similarity beyond supplied groups
and these mechanical checks is not automatically certified.

A separate provenance JSON contains `schema_version: 1` and `sources`, each
with nonempty `id`, `origin`, `revision` and `license` descriptions. Optional
`files` maps relative attribution paths to SHA-256 values; they are verified
and copied. Record actual data terms, including unresolved conditions, rather
than substituting a software license. Choose the selected sources deliberately.
No blanket redistribution right or weight license is assigned.

```sh
./llm/reranker_large/scripts/data.sh \
  --documents /path/to/reviewed-documents.jsonl \
  --provenance /path/to/document-provenance.json
```

Preparation reports split counts and non-ASCII byte-fallback scalar counts.
The 8K tokenizer reserves four markers and 256 bytes, leaving at most 7,932
dedicated non-ASCII characters. ASCII uses byte IDs directly. Original bytes
remain representable, but fallback can expand candidate/context token counts.

## Source-linked candidate pools

`scripts/prepare-distillation.sh` explicitly constructs unscored candidate pools
from the frozen LM documents plus a separately pinned local `raw/si` inventory.
It exports readings from the actual Rust lexicon, skips ambiguous longest
dictionary matches, and queries one persistent Rust engine process with each
sample's context. Readings are automatically dictionary-derived, **not reviewed
pronunciation labels**. No original target is injected into the candidate list.
The generator does not load a student checkpoint/Qwen or start training.

Build the offline CLI, then optionally refresh the inventory if local TXT files
have changed. Run from the repository root:

```sh
cargo build --release --locked -p si-cli
# Metadata only; records hashes, does not generate samples or train:
./llm/reranker_large/scripts/prepare-distillation.sh --freeze-sources

# Initial 10K-training-pool trial, with separate held-out source groups:
./llm/reranker_large/scripts/prepare-distillation.sh \
  --train-pools 10000 --validation-pools 500 --test-pools 500 \
  --output llm/reranker_large/data/prepared/student-15m-v1/pools-pilot

# Formal preparation defaults: train 100K, validation 5K, test 5K:
./llm/reranker_large/scripts/prepare-distillation.sh
```

Defaults use the existing `student-15m-v1/lm` tokenizer and source documents.
`--data`, `--si-root`, `--sources`, `--sampling`, `--config`, `--binary`,
`--lexicon`, `--grams`, `--engine-config` and `--output` select explicit paths;
this separate producer does not inherit the training experiment environment
variables. Existing output bundles are never overwritten. Source TXT must stay
unchanged during generation; additions/edits require freezing a fresh inventory
and using a fresh output. A retained sibling `.pools.work/` directory contains
the SQLite document/reading index and committed samples. To resume generation,
repeat the identical command with `--resume`. An interrupted initial index is
rebuilt; completed document transactions are retained once indexing is done.
Changing sampling budgets or resource hashes requires a fresh output. If
eligible samples cannot meet a source quota, generation retains its work and
reports the shortfall. Repeating with `--resume --allow-shortfall` explicitly
publishes the actual counts; it never silently redistributes source quotas.

`configs/distillation-data.json` declares the following initial proposal mix:

| Dimension | Shares |
| --- | --- |
| Sources | SI dialogues 25%, SI Workbuddy 15%, public dialogue 20%, Wikipedia 35%, Chinese technical prose 5% |
| Context length | None 30%; 1–4 tokens 25%; 5–8 tokens 20%; 9–16 tokens 25% |
| Observed span length | 1 character 15%; 2–3 characters 30%; 4–6 characters 30%; 7–10 characters 15%; 11–16 characters 10% |
| Input | Complete 45%; incomplete suffix 35%; early 1–3 letters 15%; one-letter substitution 5% |

The student distillation limit is 16 tokens per observed span/candidate, including
byte fallback; context remains at most 16 tokens and each pool at most 12 candidates.
`teacher.sh` and `pools.sh` default to `configs/distill.json`; direct Python CLI
calls must explicitly select that config. The running pretraining config retains
its prior scoring settings for strict resume compatibility. The installed app's
scoring bounds are unchanged by this offline preparation.
Proposal shares can change after eligibility checks, so inspect actual source,
context, target, input, mixed-target and candidate-count distributions in
`metadata/generation/report.json`. There are no standalone English targets;
Chinese spans containing English are eligible. Prefix/completion/correction
cases depend on what the engine actually returns. Only whole-source-consuming
nonliteral candidates are scored, including eligible completions/corrections;
prefix candidates and the literal action remain outside the scorer. The first
12 eligible candidates retain statistical order. A pool with an over-token-limit
candidate is excluded as a whole, not silently reduced. Target coverage is
reported even when the source text is absent from the pool; it is not ranking
accuracy or evidence of a unique correct answer.

Local SI files use blank-line conversation boundaries. Workbuddy role files are
kept together; `dialogues_gen/chats.txt` and other conversations use a hashed
whole-conversation template with ASCII words/numbers masked. SI groups split
90%/5%/5%; existing LM source splits stay unchanged. The generator excludes SI
document copies and cross-split exact long paragraphs against all indexed
sources, and excludes equivalent context/spelling/pool queries across splits,
giving held-out queries priority. Source files are interleaved, with a 20% cap
per SI file within its source/split quota. These checks do not establish absence
of semantic/template near-duplicates. Context comes only from the current
utterance before the target; it never treats a previous speaker's reply as text
already entered into the active field. Context-free examples deliberately omit
that field context. The known regression-derived
`synthetic-fourth-position-20261123.txt` is excluded, as are scripts, hidden
memory directories and all `eval/` data.

Generated pools retain the original LM dataset/tokenizer identity for teacher
and student compatibility. Their independent, checksummed document registry
under `metadata/generation/documents.jsonl` includes selected external SI source
documents and exact offsets. The registry, inventory, rules, report, producer
code, source notices and binary/resource hashes travel through teacher caching
and export. No pretraining manifest/checkpoint is modified. The producer lives
under `scripts/` to preserve the running pretrainer's existing code identity.
Local SI material includes AI-authored text and does not imply reviewed labels
or a blanket redistribution license.

The generated output is already a frozen `si-student-pools` bundle; feed it
directly to `teacher.sh` (use `--pools .../pools-pilot` for the pilot). It does
not need to pass through `pools.sh` again. Check the pilot's report and manually
inspect pronunciation/candidate examples before spending time on full scoring.

For externally reviewed candidate records, the separate `pools.sh` command
continues to require reviewed source spans/readings and a pinned engine/resource
snapshot. It validates records only; it does not retrieve candidates or train on `eval/`.
Record the engine/dictionary identities and any reference injection in pool
provenance. Missing targets remain recall misses in separate end-to-end tests.

For `pools.sh`, each record identifies a frozen LM document. Its split is derived from that
document; supplied conflicting splits are rejected. `document_id` is the
document's `id` from `<split>.documents.jsonl` in the frozen LM bundle.

```json
{"id":"unique-pool-id","document_id":"frozen-document-id","input":"denglu","context":"今天需要","observed_text":"登录","candidates":[{"text":"登录","language":"zh-Hans"},{"text":"登陆","language":"zh-Hans"}]}
```

Candidate identity is `(text, language)`; allowed languages are `zh-Hans`,
`en`, `mixed`. Candidate order is retained. `context + observed_text` must
occur contiguously in the source document. The observed span supports the
auxiliary LM loss; it is **not automatically a unique ranking answer**.
Optional `reference_indices` requires `labels_reviewed: true`; it must be
provided deliberately. Teacher winners and source observations are not
automatically turned into reviewed references.

```sh
./llm/reranker_large/scripts/pools.sh \
  --records /path/to/reviewed-pools.jsonl \
  --provenance /path/to/pool-provenance.json
```

Pools contain 2..12 candidates, each at most 16 student tokens with the distillation config. The observed
span must fit the same budget. An over-limit pool is excluded and counted;
it is never truncated or silently reduced to a different pool. Retain these
counts when measuring coverage. Effective context is the longest scalar-safe
suffix fitting 16 student tokens. Identical normalized context/spelling/pool
queries cannot cross splits, even if candidate order differs. All splits need
eligible pools. The 64-token student window covers these deployed limits.

## Frozen local Qwen teacher

### App-aligned replacement protocol

The legacy `teacher.sh`/`distill-pilot.sh` cache uses Qwen conditional sums
against student per-scalar means. Keep it as a historical baseline. New training
uses `configs/distill-app-v4.json` and protocol `si-app-model-adjustment-v4`:

- With effective context, teacher and student both use summed conditional log
  probability in bits. Subtract the highest conditional score in the model pool
  and clip to `[-8, 0]` before applying model weight 0.8. Do not subtract a BOS
  baseline or add a lift reward.
- Without context, both use summed BOS log probability in bits without output
  length normalization. Subtract the highest pool score and clip to `[-8, 0]`
  before applying weight 0.8; adjustments range from -6.4 to zero bits.
- Add adjustments to native statistical scores before listwise KL. Ordinary
  whole candidates outside the inference pool use the lowest pool adjustment;
  identical scored text reuses its actual value. Explicitly exempt paths keep
  zero adjustment. With no valid pool, all statistical scores remain unchanged.

The v4 mapping rejects v1/v2/v3 caches that used BOS per-scalar rewards,
contextual lift or zero adjustments outside the model pool. Regenerate matching
teacher caches explicitly; existing trained runs and artifacts are not rewritten
or resumed under the new mapping. The v3 configuration and artifacts remain
separate from the new v4 preset and output paths.

The App configuration and this preset both use 16 candidate tokens, 16 context
tokens and 12 selected model rows. The App embeds `config/si.conf` at build time;
an existing installation needs rebuilding/reinstalling for changed bounds.
These offline commands do not install the app:

```sh
cargo build --release --locked -p si-cli -p si-neural
./llm/reranker_large/scripts/prepare-app-teacher.sh \
  --likelihood-cache llm/reranker_large/data/prepared/student-15m-v1/teacher-app-v1
./llm/reranker_large/scripts/distill-app.sh --check-only
./llm/reranker_large/scripts/distill-app.sh
```

Preparation writes `data/prepared/student-15m-v1/teacher-app-v4` and keeps
`teacher-pilot` unchanged. It re-queries source spellings/field contexts through
Rust with an empty private profile, no phrases and no transient preferences.
Rust exports full-precision statistical scores, punctuation fragments and the
same inference and adjustment masks as App conversion. The native `model-tsv`
rows contain inference flag, adjustment flag, statistical score, language, source
bytes, kind, lexical score and escaped output text. Completions and corrections
receive the worst-pool fallback; verbatim outputs remain exempt. Model bounds and the two-distinct-
output guard match conversion. Whole pools that cannot receive a model adjustment
still provide the auxiliary natural-text LM loss. This does not reproduce host
presentation or private personalization.

The producer reuses verified Qwen text/context likelihoods when the frozen
model/runtime match, then computes missing conditional/BOS values. The optional
`--likelihood-cache` imports only raw likelihoods from a verified App cache with
the same original parent, Qwen files/runtime, tokenizer and target limits. Old
fused logits are recomputed under the selected protocol. Omit this option when
no previous App cache exists. Both vectors
and final fused bit-valued logits are retained. Test rows are re-exported without
teacher scoring. Equivalent native queries are deduplicated across splits with
held-out priority. Logs contain progress/counts rather than source text. Its
SQLite work directory snapshots the native binary/resources/config and retains
completed rows; use `--resume` with identical inputs/code after interruption.
`metadata/app-alignment/report.json` records actual counts and exclusions.

The new independent run is `runs/student-15m-extra-v1/distill-app-v4`, starting
from the preserved 19,167-step continuation with fresh AdamW and schedule. The
initial experiment keeps the previous 1,000 updates, learning rate, temperature
and LM weight; these are not claimed optimal. Caches are bound to their exact
score protocol/parameters. Python evaluation uses fused scores and native
language/text tie order. `si-cli model-adjustments` checks the actual Rust App
component; `si-cli candidates --model <bundle>` runs full native conversion.
`si-neural rank` rejects App-tagged bundles to prevent silent evaluation with
the old per-scalar conditional protocol.

Resume an interrupted v4 training run with `scripts/distill-app.sh --resume`.
The checkpoint, cache, configuration and implementation identities must still
match. Historical runs are not resumed under a different objective or mapping.

### Sequence KL with unchanged App v4 inference

The `configs/distill-app-v4-sequence-kd.json` experiment keeps the same App v4
inference policy and 16-token context/candidate bounds, but uses
`candidate-sequence-kl-v1` for training. Teacher and student logits are summed
candidate log probabilities converted to bits and multiplied by 0.8. Subtract
their respective pool maxima for numerical stability. Do not divide by length,
hard-clip the training logits, subtract a BOS baseline or include statistical
scores in this candidate-only KL. Deduplicate identical output text across
language identities for the loss; inference retains language-aware identities.
The student still has the auxiliary observed-span LM loss with weight 0.2.
Observed source text does not become an automatic ranking label.

`scripts/prepare-sequence-kd.sh` verifies the existing `teacher-app-v4` cache,
raw Qwen scores, fused App scores, native resource hashes and token bounds.
It removes inactive model pools and writes the independent immutable
`data/prepared/student-15m-v1/teacher-app-v4-sequence-kd-v1` derivative. The
prepared split counts are 8,410 train, 431 validation and 428 test pools. Test
rows remain teacher-unscored. Source documents, notices, raw likelihoods and
split assignments are preserved; no new Qwen inference or training is needed.
Existing App v4 teacher logits remain in the derivative for inference evaluation,
while training reads the selected candidates' raw conditional/BOS likelihoods.

The derivative also contains a hashed Python runtime and config snapshot under
`metadata/sequence-kd/`. The training wrapper executes this snapshot and checks
the selected archive SHA-256 and unchanged App config. Concurrent workspace
code edits cannot silently change the objective. Do not edit this immutable
bundle; prepare another version if the objective or App resources change.

```sh
# Already prepared locally; only run preparation again with a fresh --output.
./llm/reranker_large/scripts/prepare-sequence-kd.sh

# Read-only CPU compatibility check: no run directory or optimizer is created.
./llm/reranker_large/scripts/distill-sequence-kd.sh --check-only

# Explicit formal training, to be started by the operator.
./llm/reranker_large/scripts/distill-sequence-kd.sh

# Resume this same experiment after interruption.
./llm/reranker_large/scripts/distill-sequence-kd.sh --resume
```

The run is `runs/student-15m-extra-v1/distill-app-v4-sequence-kd-v1`. Its initial
weights are the archived continued-pretraining step 19,167, SHA-256
`d8b62715b60064256cbb3c9c5fc5a9651e395ae3e1c73c22faab2f51ac8e74ba`.
It starts a fresh AdamW optimizer and counters. The preset retains the previous
1,000-step schedule, 100 warmup steps, learning rate 5e-5, batch 4 with four
accumulations, temperature 2 and validation/save every 100 steps. This isolates
the loss-path change and removal of inactive pools; it is not an optimized
large-data recipe or a claim of improved ranking quality.

Validation in the training log names the sequence-KL objective. It is not App
ranking accuracy, and its scale must not be compared to the old fused-KL loss.
After training, evaluate with exact App v4 fusion and the same frozen regression
used for the archived pretraining baseline; also check generic LM retention.
Do not promote a checkpoint solely because sequence KL decreased. For the
held-out teacher-pool diagnostic, use the prepared derivative explicitly:

```sh
./llm/reranker_large/scripts/evaluate.sh \
  --checkpoint llm/reranker_large/runs/student-15m-extra-v1/distill-app-v4-sequence-kd-v1/best.pt \
  --data llm/reranker_large/data/prepared/student-15m-v1/lm \
  --pools llm/reranker_large/data/prepared/student-15m-v1/teacher-app-v4-sequence-kd-v1 \
  --split validation \
  --output llm/reranker_large/reports/sequence-kd-v1-validation.json
```

### Targeted coverage and score-blind validation

`scripts/prepare-coverage.sh` prepares an additional **unscored** contrast
collection, without changing an existing teacher cache, training run or legacy
regression fixture. It derives same-spelling edit patterns from the 45 native
regressions and mines new natural source spans from the existing read-only pilot
index. The 49 dictionary-verified contrast patterns all have new examples,
representing the error types of all 45 original cases. Those original contexts,
full references and queries are exclusions, not training rows.

The local `data/prepared/student-15m-v1/coverage-v1` snapshot contains:

| File | Count | Role |
| --- | ---: | --- |
| `train-cases.jsonl` | 5,844 | New source-linked same-spelling contrast pools |
| `independent-validation.jsonl` | 233 | Newly authored, score-blind intended answers |
| `validation-review.jsonl` | 233 | Pending text-only linguistic review, without model predictions |
| `source-documents.jsonl` | 3,767 | Exact selected source documents and source groups |
| `patterns.json` | 49 | Short-span sound contrasts, with diagnostic origin IDs |

Training includes 4,407 contextual single-character/short-word cases and 1,437
context-free natural phrase windows. Each pool contains two complete,
pronunciation-compatible alternatives within the student's 16-token target
limit. Contexts also fit 16 tokens. These are explicit contrast pools; forced
alternatives must not be presented as native decoder recall. Source text is an
auxiliary LM span, not automatically ranking gold. Alternate focus readings,
such as polyphonic characters, must share a declared maintained-dictionary
reading; known longer lexical readings are not overridden by character guesses.
Some patterns are rare and have only one example; inspect per-pattern counts in
`audit.json` before choosing mixture weights.

The validation seeds in `data/coverage/independent-families-v1.json` were authored
without consulting Qwen or student outputs. Sixteen distinct sound/word families
are withheld from the new training cases, including their lexical surfaces.
The cases comprise 128 contextual and 105 context-free examples. Twenty-three
proposed full-phrase cases failed strict unambiguous-reading checks before any
model scoring. Every contextual seed remains. The retained sequence is sealed
by a manifest hash. Do not retire or relabel model failures after evaluation;
record text-only review decisions as a new version with reviewer provenance.
These are **AI-authored, unreviewed intentions**, not independent human gold.
They are independent of the new mining families and model-error filtering;
unseen pretraining language/semantics are not certified.

The producer verifies old fixture hashes and excludes their exact queries,
complete phrase references of at least four characters, similar same-spelling contexts and normalized character
trigram near-duplicates. It also excludes prior pilot/App/sequence-KL query,
document and source-group identities, scans only source `train` documents and
caps each pattern at 160 and each document at two cases. Training and new
validation have no overlapping query or held-out lexical family surface.
These deterministic lexical checks do not prove absence of every semantic
paraphrase; independent linguistic review remains necessary. Original source
terms/notices and the read-only index identity are retained. Generated source
text stays local under ignored prepared-data paths.

The existing pilot source index is a prerequisite. To regenerate under the
current code, use a fresh output directory; existing snapshots are immutable:

```sh
./llm/reranker_large/scripts/prepare-coverage.sh \
  --output llm/reranker_large/data/prepared/student-15m-v1/coverage-v2
```

This command performs no model inference, teacher-score filtering or training.
The case schema is `si-coverage-cases-v1`, not a scored `si-student-pools` cache;
it cannot be passed directly to the trainer. Next, score only the training
contrasts with the frozen local teacher and prepare a separately versioned
training mixture. Keep `independent-validation.jsonl` outside teacher-derived
training labels and optimization. Review its intended answers without model
predictions, then evaluate all models against the sealed version. The legacy
regression remains unchanged as a separate post-evaluation diagnostic suite.

### Matched LM replay experiment

`scripts/replay_experiment.py` freezes a separate no-replay / 25% old-LM-replay
experiment. Both arms start from the same archived 19,167-step weights, use the
existing sequence-KL teacher cache, and retain its learning rate, optimizer,
temperature, candidate objective and 1,000-update ceiling. The new 5,844 coverage
cases are deliberately not mixed into this comparison. Preparation freezes the
runtime, source identities, native validation pools and selection policy before
training; it performs no teacher scoring or training itself.

```sh
llm/.venv/bin/python llm/reranker_large/scripts/replay_experiment.py prepare \
  --experiment .build/replay-experiment-20261128/frozen

llm/.venv/bin/python \
  .build/replay-experiment-20261128/frozen/runtime/llm/reranker_large/scripts/replay_experiment.py \
  train --experiment .build/replay-experiment-20261128/frozen --arm control

llm/.venv/bin/python \
  .build/replay-experiment-20261128/frozen/runtime/llm/reranker_large/scripts/replay_experiment.py \
  train --experiment .build/replay-experiment-20261128/frozen --arm replay
```

Use a fresh preparation directory for another experiment. Run the two arms
sequentially on MPS. Their separate outputs are `distill-replay-control-v1` and
`distill-replay25-v1` under `runs/student-15m-extra-v1/`. Append `--resume` to
resume an interrupted, unfinished arm with its frozen runtime; completed runs
cannot silently restart. Checkpoints preserve optimizer, pool position, replay
sampler and CPU/accelerator RNG state.

To test a lower learning rate after this comparison, prepare another snapshot
with `--learning-rate 0.00001 --run-tag lr1e5` and a fresh `--experiment` path.
These options apply only to preparation; training cannot override frozen
settings. Its replay run becomes `distill-replay25-lr1e5-v1`. Compare it with
the first replay arm to isolate the learning-rate change, and keep using the
same sealed development cases without relabeling failures.

The replay arm preserves the number/order of candidate pools per update. It
adds about one old-LM target for every three candidate/observed-span target
exposures, sampling only old `train` windows with replacement. The loss is
`0.75 * mean_pool_loss + 0.25 * mean_replay_LM_loss`. The target-token quota
and mean-loss weighting are distinct, recorded choices. Exact normalized
validation/legacy-regression phrases of at least four characters are excluded
from sampled replay windows. These lexical checks do not establish semantic
novelty or remove shared short words from pretraining.

Every 50 updates, selection requires a strict improvement in native fused
top-one count on all 233 sealed synthetic intentions **and** old-LM validation
loss less than 0.1 nat above its initial value, using a fixed 65,536-target
validation budget. Ties retain the earlier checkpoint. Six consecutive checks
without an eligible improvement stop training. Step zero is saved as the
fallback `best.pt`; a completed run can therefore select the original weights
and must not be described as successful distillation. Teacher-validation KL is
logged separately and does not select best.

The 233 answers remain AI-authored and unreviewed. Once used for selection,
this split is a development validation set, not an independent final test.
Evaluate the unchanged legacy regression only after checkpoint selection;
its historical teacher-informed edits still limit interpretation. Neither a
validation gain nor a small LM loss change guarantees real typing accuracy or
closeness to Qwen. No command installs or promotes an app model.

### Historical conditional-sum teacher

```sh
./llm/reranker_large/scripts/teacher.sh --model /path/to/local/Qwen2.5-0.5B
```

The adapter expects the Qwen2.5-0.5B Base architecture, uses local files only,
disables remote model code, and records every local file hash, dtype, device,
thread count, library version and scoring protocol. The official model origin
is [Qwen/Qwen2.5-0.5B](https://huggingface.co/Qwen/Qwen2.5-0.5B); retain its
Apache-2.0 notices. A directory name is not proof of an upstream revision.
File hashes identify the bytes actually used, and files are rechecked after
scoring. Available LICENSE/README files accompany the cache and export.

Teacher scores follow the previously tested protocol: BOS plus effective
context, context/candidate encoded separately, sum candidate-token log
probability, no context loss, candidate EOS, chat template or length
normalization. CPU uses FP32; MPS/CUDA use FP16. Teacher and student tokenizers
need not match because only candidate-aligned score vectors cross the boundary.
Final test pools are copied unchanged without being scored by the teacher.

## Train and distill, only when requested

```sh
./llm/reranker_large/scripts/pretrain.sh
./llm/reranker_large/scripts/distill.sh
./llm/reranker_large/scripts/resume.sh --stage pretrain --max-tokens 300000000
./llm/reranker_large/scripts/resume.sh --stage distill --max-steps 15000
```

Pretraining begins from random weights. Distillation starts a new AdamW run
from compatible pretraining weights, with the exact same model and tokenizer.
Ordinary initialization requires the same LM dataset. A continued checkpoint
from another corpus also requires `--init-data`: the frozen source manifest
must match that checkpoint and prove the candidate-pool LM dataset is a recorded
ancestor, with frozen tokenizer bytes and ancestor exclusions intact. Merely
sharing a vocabulary is insufficient. The source manifest, parent checkpoint
hash and continuation lineage are retained in checkpoints and inference exports.
Candidate pools keep their existing LM identity and teacher scores; no dataset
or checkpoint identity is rewritten. Distillation never loads Qwen; it reads
cached vectors. Resume retains the existing strict identity checks.

For a scored 10K-training/500-validation pool pilot, use the separate
`configs/distill-pilot.json`: 1,000 updates with effective batch 16, approximately
1.6 passes over 10K pools. Its learning-rate schedule also ends at 1,000 updates;
validation/checkpoints run every 100 updates. The default 10,000-update
distillation config would expose a 10K pool dataset approximately 16 times.
The selected pilot now starts from the separately preserved additional-corpus
checkpoint at `runs/student-15m-extra-v1/snapshots/continued-step-019167/best.pt`,
with `data/prepared/student-15m-extra-v1/lm` as initialization provenance. It
continues to use `student-15m-v1/teacher-pilot` and its original LM bundle.
Its distinct run is `runs/student-15m-extra-v1/distill-pilot`:

```sh
# Read-only CPU validation; does not create a run or optimizer:
./llm/reranker_large/scripts/distill-pilot.sh --check-only
# Explicitly start the selected 1,000-update experiment:
./llm/reranker_large/scripts/distill-pilot.sh
```

The wrapper supplies `--config`, `--data`, `--pools`, `--run`, `--init-checkpoint`
and `--init-data` explicitly; appended options can override those defaults.
It does not replace the preserved 60K or continued archives. `--check-only`
is also available on the general `distill.sh` command for initialization checks.

This is a validation experiment, not a measured optimal training budget. Do not
use final-test results to select checkpoints or change its source dataset.

The default objective is `T² KL(softmax(teacher/T) || softmax(student/T))`
plus `0.2 * observed-span LM loss`, initially `T=2`. Student scores use mean
log probability per Unicode scalar, matching the current Rust score policy.
Teacher scores retain the established sum protocol. Their scales and
variable-length behavior differ; choose temperature/weights with an independent
validation set. Reviewed-reference loss is supported but defaults to zero.
No token-level KL or teacher/student vocabulary alignment is implied.

Best pretraining weights follow validation token loss. Best distilled weights
follow the configured validation objective, not final-test answers. LM
validation has a target-token budget; distillation has a separately named
`validation_pools` budget and reports partial evaluation. Both use a fixed
permutation. Logs contain counts/losses, never source text or model inputs.

Strict resume binds all reused code, config, model/tokenizer, dataset/cache
identity, device type, PyTorch version and threads. It restores optimizer,
RNG, shuffled-epoch cursor and counters. Only step/token budgets may be
extended; extending them does not restart the original learning-rate schedule.
Source/config changes require a new run. Checkpoints are atomic; normal
periodic saves are not a promise to retain the current incomplete update.
Exact CPU resumed weights are regression-tested. MPS/CUDA training and resume
need separate device validation; CUDA is not established by CPU tests.

## Evaluation and export

```sh
# Use --checkpoint explicitly for a pretraining checkpoint:
./llm/reranker_large/scripts/validation.sh
./llm/reranker_large/scripts/evaluate.sh --split validation
./llm/reranker_large/scripts/evaluate.sh --split test --output /path/to/fresh-test-report.json
./llm/reranker_large/scripts/export.sh
cargo build --release --locked -p si-neural
./llm/reranker_large/scripts/benchmark.sh
```

Token perplexity, reviewed-reference Top-1/MRR, teacher agreement, token-limit
coverage and latency are separate measurements. Metrics requiring reviewed
references or teacher scores are unavailable (`null`) when those are absent.
Ranking reports retain an abstention's original pool order. Fixed-pool scores
cannot establish decoder recall. Keep `eval/` outside preparation/training
and model selection; its current Qwen-informed regression revision is not an
independent generalization test.

Exports include `model.pt`, `rust/model.json`, `rust/weights.f32`, source
notices, pretraining/pool manifests, teacher hashes and initialization lineage.
Exporting a distilled student requires its matching teacher cache. Exports
do not install or replace the app model. The benchmark checks synthetic
Python/Rust score parity and warmed resident Rust JSONL round-trip timings;
it excludes model load, host reads, decoder search, native UI and key delivery.
It does not establish representative typing quality or host responsiveness.
