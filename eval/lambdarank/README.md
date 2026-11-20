# Offline LambdaRank starter experiment

Python trains LightGBM offline with real candidates and versioned features
exported by the Rust engine. A matching v5 model bundle can be exported for
macOS builds through the [input ranking workflow](../../llm/README.md#experimental-input-ranking).

## Data and scope

- `train.jsonl`: 120 authored queries, used for fitting.
- `validation.jsonl`: 65 separate authored queries, used for early stopping and
  development comparison. This is **not an untouched test set**.
- `../ranking/test.jsonl`: the existing 220-query frozen regression suite. The
  pipeline reads it only to reject cross-split overlap; it never trains, selects
  parameters or reports model quality against these test answers.

The starter data was authored specifically for this experiment with AI
assistance, under the repository's GPL-3.0-only license. It contains Chinese
words/sentences, continuous English, mixed input and explicit synthetic preceding
context. It does not originate from user history, host fields, personal phrases,
WeType assets or downloaded text. These are intended scenario answers, not
independent human annotations or representative natural typing observations.
There is no claim of semantic independence from all existing corpora. Split
checks cover family, normalized spelling and reference text, not all paraphrases.

The v2 expansion adds 24 training and 16 validation queries, including same-family
spelling variants, explicit separators, abbreviated spellings and contextual
homophone choices. The families are assigned to files explicitly, with no random row split
or combinatorial template expansion. Cases are not selected for candidate
reachability. Missing targets remain missing; reference answers never enter Rust
requests and are never inserted into the candidate pool.

V3 adds four explicitly authored typo queries to each split, retaining their
original scenario families. These include omissions, adjacent swaps and a neighbor
replacement; examples are retained whether or not the decoder retrieves the target.
The earlier 88/42 snapshots remain immutable for the v2/v3 controlled comparison.

V5 adds four English completion scenarios per split and six explicitly authored
pre-request choice snapshots across both splits. It uses no personal archives.

### Add more examples

Use one JSON object per line. Only `input` and `references` are required.

```json
{"input":"qingdakaideng","references":["请打开灯"]}
{"input":"chnogdian","references":["充电"],"category":"pinyin-correction","family":"charging"}
```

Context defaults to unavailable and languages default to Chinese and English.
Supply `context` when there is preceding text, `context_available: true` for a
known empty field, or `languages` to test a single language. IDs default to a
stable hash of the request. `category` defaults to `general`; mark typo queries
`pinyin-correction` for correction calibration. Input and references preserve
exact casing, separators and spaces. Several acceptable outputs may be listed.
Record shared source and license information in a dataset manifest. Existing
row-level `origin` and `note` fields remain readable.

Set the same `family` wherever related sentences, paraphrases or spelling
variants are present, and keep them in the same split. Validation rejects
cross-split declared families, normalized spellings (including umlaut aliases and spelling
separators) and normalized reference texts. Duplicate exact query/context/language
requests within train or validation are rejected too. Spelling aliases and
separator variants may share a family within one split. This conservative spelling
check also rejects the same spelling in different splits with different context.
Keep private contributions in `eval/private/` and use explicit paths; never commit
them or silently train on live Input History, Personal Learning or Sentence Learning.

Labels are binary: exact reference match = 1, other retrieved candidate = 0.
Zero means a **weak negative for the authored scenario**, not proof of incorrect
Chinese or English. A query without both labels cannot teach a pairwise ranking;
training and early stopping exclude such groups and report their counts. All
queries, including empty pools and missing targets, remain in reported metrics.

### Generate 100,000 training queries

```sh
python3 scripts/lambdarank/generate_training.py
python3 scripts/lambdarank/pipeline.py validate \
  --train eval/lambdarank/generated/training-100k-v1/train.jsonl
```

The generator preserves the maintained starter, validation and regression sets.
It selects distinct intended outputs from the maintained Wanxiang-derived base
vocabularies and builds English and mixed sentences from SI-authored templates.
The collection covers Chinese words and phrases, contextual homophones, umlaut
aliases, explicit separators, abbreviations, three single-edit Pinyin typo types,
English words, word segmentation and completion, mixed input, and synthetic
prior choices. The local manifest records counts, attribution and SHA-256 hashes.
These derived and templated queries use synthetic scenario labels and do not
establish natural typing or held-out neural model quality.

Select the generated file with `train --train PATH --model-correction-pool
--output RUN` or with `prepare --train PATH` in the two-step neural workflow.
Preparation exports candidates in batches. The fit still loads the prepared
feature matrix in memory. Feature availability depends on candidate retrieval,
the chosen schema and checkpoints, and the paired base and user statistics.

To generate the second 100,000-query batch and a combined training file:

```sh
python3 scripts/lambdarank/generate_training.py \
  --extend eval/lambdarank/generated/training-100k-v1/train.jsonl
python3 scripts/lambdarank/pipeline.py validate \
  --train eval/lambdarank/generated/training-100k-v2/train-combined.jsonl
```

The second batch excludes the first batch's normalized input spellings and
reference text. It adds new Chinese document scenarios and English and mixed
templates while keeping the earlier vocabulary and spelling categories.
The `training-100k-v2/` directory contains `train.jsonl` for the new batch and
`train-combined.jsonl` for both batches. Its manifest records the input batch
checksum and the combined file's split counts and checksum.

### Generate focused ambiguity training queries

`python3 scripts/lambdarank/generate_ambiguities.py` builds a separate
60,000-query collection under `eval/lambdarank/generated/ambiguities-60k-v1/`.
The 30,000 homophone cases cover alternate outputs with identical toneless
syllables, including 15,000 with preceding text. The 30,000 segmentation cases
contain 18,000 competing word cuts and 12,000 competing syllable cuts.

The generator anchors the expected text in the maintained Chinese dictionary
and checks both competing paths against dictionary readings. Keep any reserved
experiment splits out of the batch with one `--exclude PATH` per split. The
generator also excludes overlap with the maintained validation and frozen
regression queries and duplicate requests from the existing training pool.
Select the combined additions with `--train` and the generated `train.jsonl`.
The separate `evidence.jsonl` records candidate paths for auditing. Normal
feature export still retrieves its own candidates. The labels encode synthetic
intent backed by lexical attestations.

## Setup and run

Run from the repository root with Python 3.12 and the documented Rust toolchain.
On macOS the official LightGBM wheel requires OpenMP (`brew install libomp` if
missing). See the [official installation guide](https://lightgbm.readthedocs.io/en/stable/Installation-Guide.html#macos).

```sh
python3 -m venv .venv/lambdarank
.venv/lambdarank/bin/python -m pip install -r scripts/lambdarank/requirements.txt
cargo build --release --locked -p si-cli

python3 scripts/lambdarank/pipeline.py validate

.venv/lambdarank/bin/python scripts/lambdarank/pipeline.py train \
  --pinyin-correction --output eval/lambdarank/runs/starter-v5-local

.venv/lambdarank/bin/python scripts/lambdarank/pipeline.py evaluate \
  --bundle eval/lambdarank/runs/starter-v5-local/bundle \
  --run eval/lambdarank/runs/starter-v5-local \
  --output eval/lambdarank/runs/starter-v5-local/recheck.json
```

`train` without `--bundle` generates features first and saves the prepared snapshot
under the run's `bundle/` directory. Standalone `prepare` uses the same defaults.
Use `train --bundle PATH` to fit from an existing snapshot.

The default base resources are `.build/si-data/main.silex` and its paired
`words.sigram`. An explicit `--lexicon` without `--grams` supports a lexicon-only
experiment. Both commands accept `--train`, `--validation` and `--binary` during
preparation. Use a new output path when regenerating features or fitting a model.
Commands refuse to overwrite previous artifacts and reject changes to the
checksummed files in prepared bundles.

`model.txt` is the native LightGBM text model, `run.json` records model identity,
versions, feature order, parameters and the prepared manifest hash. `report.json`
contains baseline/model comparisons, per-category results, per-query ranks,
training exclusions and best iteration. `evaluate` reloads the model and
recomputes validation metrics against the original bundle. Training also checks
saved-model prediction equivalence. This is verification, not a new held-out test.

Preparation records dataset, binary, lexicon and gram hashes, Rust source hashes,
Git revision and working-tree Rust diff hash. Candidate rows contain their source
query and features, so the bundle remains inspectable after source edits. Runs
record the training script hash and pinned dependency-file hash. Prepared pools,
models and reports stay under ignored directories; commands create new artifacts
with owner-only permissions. No input text is sent over the network or printed
as diagnostics. Explicit dataset artifacts necessarily contain input/output text.

## Candidate and feature contract

The legacy protocol exports the first **64 eligible complete, noncompletion dictionary
paths**, in current Rust order. It excludes literals, prefixes, personal,
preferred and verbatim paths. Distinct language identities remain separate even
when output bytes match. Empty groups have explicit terminators. This does not
represent the native candidate window and cannot recover answers removed by the
existing beam or final pruning. `total_eligible` counts eligible engine outputs
before the export cap, not all possible paths.

`si-cli rank-features BASE [--grams GRAMS] [--pinyin-correction]` reads one TSV request per line:
hex-encoded UTF-8 source, hex-encoded UTF-8 context, enabled-language list. Output
starts with a schema/name header; each row is language, hex output, comma-separated
nullable numeric features, followed by `END<TAB>total_eligible` for every request. This keeps
newlines/tabs and Unicode exact without adding a serialization dependency.

The shared Rust `ranking_features` module defines `si-rank-features-v3` with
43 features. Python's `FEATURE_GROUPS` and Rust's `NAMES` are the ordered contract:

| Group | Features |
| --- | --- |
| Frequency (5) | Mean/minimum log counts; sum/mean/minimum unigram log probabilities |
| Internal grams (6) | Sum/mean/minimum internal conditional log probabilities; observed-hit ratio, maximum hit order, mean log support over hits |
| Context (6) | Availability, sentence-start flag, recognized history length, whole-candidate conditional log probability and gain, maximum cross-boundary hit order |
| Spelling (4) | Exact-match flag, abbreviated Chinese syllable ratio, missing completion letters, explicit separator alignment |
| Structure (4) | Actual path token count, single-character fraction of Chinese tokens, language switches, categorical candidate language |
| User lexicon (6) | Availability, observed-word ratio, mean/minimum log counts, mean smoothed user unigram log probability and lift |
| User grams (6) | Availability, internal hit ratio/support/gain, cross-boundary log support, whole-candidate user-gram gain |
| Correction (6) | Corrected flag, edit count, actual path correction cost, missing-key/neighbor-key/adjacent-swap indicators |

All observations use the exact selected lexical derivation, including user IDs.
Whole-candidate context scoring retains external history across successive candidate
words until bounded N-gram history or a language change removes it. It is diagnostic:
production retains its existing first-word context adjustment and ranking policy.
Probabilities use log2; counts use ln(1 + count). User unigram probabilities use
32 observations of the shared-vocabulary base distribution as a smoothing prior.
User gram gains compare with/without user grams at identical user-unigram settings,
so unigram personalization is not counted again. Cross-boundary user support sums
the log support of each token's highest observed gram that still reaches into
external history. User candidate gain includes all candidate transitions, while
internal gain excludes the first word. Single-token internal features are missing.

Missing values are TSV `null`, JSON null and LightGBM missing values, never fabricated
zeros. No user resource means missing user statistics; an available model with no
matching count supplies zero count. Empty user lexicons are treated as unavailable.
A request can append a fourth TSV column, `0` or `1`, for context availability;
JSONL accepts `context_available`. Known empty context means field start; absent
metadata preserves legacy empty-string-as-unavailable semantics. Sentence position
uses terminal punctuation/newlines and closing quotes, a heuristic rather than a
linguistic sentence parser. An unavailable context cannot contain nonempty text.

`prepare --pinyin-correction` enables the current bounded, default-sensitivity
correction decoder. Corrected full candidates join the same capped pool. Features
use its real single edit and cost (8 bits for missing/swap, 11 for neighbor).
Corrections are not exact spelling. Prefixes, completions, personal and verbatim
paths remain excluded; completion-missing-letters is therefore constant zero in
this experiment. Separator alignment is also constrained by candidate generation.
These constants are retained as defined signals, not evidence of learned utility.

Preparation automatically loads the pair `.build/si-data/user.silex` and
`.build/si-data/user.sigram` when both files are present. With neither file, the
user statistics are unavailable. A partial pair causes an error. Use
`--without-user` to prepare without a user snapshot or pass `--user-lexicon PATH`
and its paired `--user-grams PATH` to use a different snapshot. The legacy v2
schema has no user features.

Stage an immutable snapshot that predates **every** training and validation
request and excludes the target submissions. `--user-snapshot-note TEXT` records
the source and cutoff when known. Resource hashes are verified before and after
export, and the manifest records whether user resources were used. Preparation
reads staged local files and does not discover live profiles or import Input
History. Use synthetic fixtures to verify user feature calculations.

Legacy v1/v2 bundles remain readable. `prepare --schema si-rank-features-v2` exports
the old features for a resource-matched comparison without corrections or user
resources. Do not compare quality across different candidate pools without reporting
that difference. Extraction never receives reference answers. Normal conversion
allocates no diagnostic evidence; regression tests remove evidence and compare
candidate order, scores, spans and correction metadata exactly.

Training uses LightGBM 4.6.0, `objective=lambdarank`, gains `[0,1]`, shallow trees,
one thread, fixed seed and deterministic column-wise training. The default maximum
is 300 rounds with 30-round early stopping on validation NDCG@1; `--rounds` changes
the maximum. These are initial experiment defaults, not tuned quality claims.
Reports show pool recall, Top-1/5, MRR and NDCG@5. Missing-gold NDCG is explicitly
reported as zero. Pool recall separates retrieval failures from ranking failures.

## Compare feature groups

Use the same prepared bundle for all comparisons, so candidates, labels and
resource versions remain fixed:

```sh
.venv/lambdarank/bin/python scripts/lambdarank/pipeline.py ablate \
  --bundle eval/lambdarank/prepared/features-v3-typos-20261119 \
  --output eval/lambdarank/runs/features-v3-comparison
```

V3 ablations train `all`, `without_user`, and each `without_GROUP` variant on
the same candidates. Each child run retains its model, feature order, importance,
metrics and per-feature observed/distinct training counts. `v1` selection is only
available with legacy bundles. Default selection is `all`. Validation is used for
early stopping and development comparison, not an untouched quality test.

The [v3 development results](FEATURES_V3_RESULTS.md) record the controlled comparison,
typo expansion and current limitations.

## Merge neural candidates and scores

Run `prepare` with both local checkpoints using the PyTorch environment from
the [model workspace](../../llm/README.md). The resulting v5 bundle is ready
for the same LightGBM `train` and `evaluate` commands in the LambdaRank environment.

```sh
llm/.venv/bin/python scripts/lambdarank/pipeline.py prepare \
  --pinyin-correction \
  --pinyin-model llm/pinyin_to_text/runs/small-pinyin-lexical-v1/best.pt \
  --reranker-model llm/reranker_small/runs/small-character-v1/best.pt \
  --output eval/lambdarank/prepared/neural-v5

.venv/lambdarank/bin/python scripts/lambdarank/pipeline.py train \
  --bundle eval/lambdarank/prepared/neural-v5 \
  --output eval/lambdarank/runs/neural-v5
```

The first 64 eligible SI results retain their order. Pinyin-to-text contributes
up to eight hypotheses by default (`--pinyin-beam` from 1 to 32) on requests with
Chinese enabled. It receives normalized toneless spelling. A contextual checkpoint
also receives preceding text and up to three paths derived by the Rust feature
exporter from the typed spelling and base lexicon, using the same segmentation
as the app. A contextual checkpoint skips generation when there is no complete
path. Spelling-only checkpoints use the spelling alone. The generator's literal fallback stays outside the
training pool. Generated outputs use Han and Latin script to infer language, and
only outputs for enabled languages enter the pool.

The union deduplicates by exact text and language. A shared candidate keeps the
Rust features and both source flags. Model-only candidates retain their language
and use nulls for Rust path features. `reranker_small` scores every supported
surface with the same preceding context and shared context window. Identical text
in different language identities shares a score and keeps separate candidate rows.
Unsupported candidates, including those exceeding the model context, retain their
positions and have missing neural scores. V4 adds six columns to the 43 in v3.

| Feature | Meaning |
| --- | --- |
| `from_si_engine` | Candidate was retrieved by SI |
| `from_pinyin_model` | Candidate was generated by Pinyin-to-text |
| `pinyin_model_beam_rank` | One-based position in the returned hypotheses |
| `reranker_logp_sum` | Sum of candidate-token natural log probabilities given preceding text |
| `reranker_logp_mean` | Log probability per reranker token, including byte fallback tokens |
| `reranker_context_gain` | Change in total log probability relative to empty context, missing when context availability is unknown |

The manifest records checkpoint and code hashes, model dataset IDs, tokenizer
digests, device, beam and score settings. Validation reports SI-only order, the
merged order, `reranker_small` order with its configured length penalty and
LambdaRank order. `--feature-set without_neural` keeps the merged pool and removes
the six added columns. `without_neural_reranker` removes the three LM scores.
Without neural checkpoints, `prepare` defaults to `si-rank-features-v5-lexical`.
Select `--schema si-rank-features-v3` or `--schema si-rank-features-v4` to
reproduce an older feature layout. To run the exported full model in a local macOS development build, use the
[input ranking workflow](../../llm/README.md#experimental-input-ranking).

The first v4 run used beam 8 and the two checkpoints in the command above.
Across 46 development queries, adding generated candidates raised pool recall
from 43 to 44. The merged validation pool contained 2,460 candidate rows,
including 289 generated-only rows, and every row received an LM score.

| Ranking | Top-1 | Top-5 |
| --- | ---: | ---: |
| SI order | 25/46 | 37/46 |
| Small LM on the merged pool | 22/46 | 30/46 |
| LambdaRank on the merged pool with v3 columns | 30/46 | 38/46 |
| LambdaRank on the merged pool with all v4 columns | 31/46 | 40/46 |

Compared with the spelling checkpoint's exact normalized training pairs, 16 of
the 46 validation queries have a matching spelling and reference in that training
set. On the other 30, v4 scored 18/30 Top-1 and 24/30 Top-5, versus 19/30 and
23/30 with v3 columns on the same pool. The 46 queries also serve early stopping,
so both comparisons are development results. Detailed reports are in the ignored
`runs/neural-v4-20261119/` and `runs/neural-v4-no-neural-20261119/` directories.

## V5 candidate evidence

V5 adds 12 candidate-level signals to the previous 49-column neural layout.
The shared Rust extractor supplies these columns to both the CLI and the app.

| Group | Added features |
| --- | --- |
| Path counts | Abbreviated token count, abbreviated and total Pinyin syllable counts, English token count, single Han token count |
| Match | Completion flag and whether the output has an exact direct dictionary match |
| Statistical evidence | Base gram availability, lexical path score in bits, classical field-context adjustment in bits |
| Prior choices | Whole-spelling frequency bonus and length-weighted token frequency bonus, kept separate from user lexical and gram statistics |

The v5 pool includes dictionary completions that consume the whole typed span.
The existing missing-letter feature now records their actual untyped suffix.
Prefixes, literal text, personal phrases and verbatim paths remain outside this
pool. Existing search costs and product ordering policies still apply. The Rust
loader accepts both v4 and v5 models and routes them to their corresponding pool.

An optional `prior_choices` list on a source JSONL row supplies synthetic or
explicitly reviewed prior observations. Each item has `text`, `language` and
`bonus` (0–32). Add `token_spelling` for a token observation. Entries without it
apply at the whole-input span. These observations must predate the request. Rust
applies them through the same preference inputs as runtime conversion. Missing
eligible observations yield null; an observation set with no match yields zero.
Prepared data does not read live profiles. `without_v5_additions` compares the old
columns on the same v5 pool, including the same completions.

## Calibrate Pinyin correction

Use `--model-correction-pool` in place of `--pinyin-correction` in the merged
preparation command. The exporter uses the same bounded one-edit pool as
native inference, reserves up to four of the 64 SI slots for corrections and
keeps candidates that fell below the statistical confidence cutoff. Clean
spellings and their authored typo variants stay in the same split.

Train a fresh full LambdaRank model on that bundle, then export it with
`scripts/lambdarank/export_runtime.py`. The export uses clean validation
queries to pick model-score margins for zero observed false suggestions in
Conservative mode and at most 5% in Higher recall. It reports clean queries
with any suggestion, how many intended corrections were retrieved, and how
many pass each margin. These are development operating points measured on
the same validation split used to select the model iteration. Held-out
quality requires a separate evaluation.

To build with a separate calibrated model directory, point the app's bundle
symlink at it after exporting the matching trees.

```sh
mkdir -p .build/si-neural-correction-pool
ln -s ../si-neural/pinyin .build/si-neural-correction-pool/pinyin
ln -s ../si-neural/reranker .build/si-neural-correction-pool/reranker
.venv/lambdarank/bin/python scripts/lambdarank/export_runtime.py \
  --run eval/lambdarank/runs/neural-v5-correction-pool \
  --bundle eval/lambdarank/prepared/neural-v5-correction-pool \
  --binary target/release/si-neural \
  --output .build/si-neural-correction-pool/lambdarank.json
ln -sfn si-neural-correction-pool .build/si-llm-pinyin
./scripts/build.sh
```

## Validation and dependency provenance

```sh
cargo fmt --all -- --check
cargo test --workspace --locked
cargo build --release --locked -p si-cli
python3 -m unittest discover -s Tests/LambdaRankTests -v
python3 scripts/generate_ranking_eval.py --check
```

The Python tests exercise real CLI export when the Release binary exists; build
it first to avoid skipping that integration test. They also cover split leakage,
missing-gold denominators, ties, identity preservation and corrupted bundles.
Rust tests cover feature units and exclusion rules. The actual training commands
above verify model fitting, persistence and reload, independently of unit tests.

Dependencies are confined to the offline virtual environment: LightGBM 4.6.0
([MIT](https://github.com/microsoft/LightGBM/blob/v4.6.0/LICENSE)), NumPy 2.2.6
([BSD-3-Clause](https://github.com/numpy/numpy/blob/v2.2.6/LICENSE.txt)), and
SciPy 1.18.1 ([BSD-3-Clause](https://github.com/scipy/scipy/blob/v1.18.1/LICENSE.txt)).
Retain their notices if distributing dependencies; wheel-bundled components have
additional notices in their distributions. The SI code/data remain GPL-3.0-only.
Model redistribution requires reviewing the actual training sources and their
terms. No third-party model, dictionary or WeType binary asset is copied here.
