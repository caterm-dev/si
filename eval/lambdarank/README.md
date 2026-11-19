# Offline LambdaRank starter experiment

This is an offline experiment, not an app model. Python trains LightGBM; the
Rust engine exports real candidates and versioned features. No model is loaded
by SI, and conversion, search limits, learning and automatic confirmation are
unchanged. Future Rust inference can load the trained model through a separately
reviewed integration.

## Data and scope

- `train.jsonl`: 92 authored queries, used for fitting.
- `validation.jsonl`: 46 separate authored queries, used for early stopping and
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

### Add more examples

Edit the two JSONL files directly; one JSON object per line:

```json
{"id":"train-distinct-scenario","family":"distinct-scenario","input":"qingdakaideng","context":"","languages":["zh-Hans","en"],"references":["请打开灯"],"category":"chinese","origin":"si-authored-synthetic","note":"Intended answer for this scenario."}
```

Use unique IDs, nonempty input and references, a string context (empty when
unavailable), and enabled languages `['zh-Hans','en']`, `['zh-Hans']` or `['en']`.
Spelling and expected output preserve exact casing, separators and spaces.
Several acceptable outputs may be listed. Record the actual origin and license
for new sources; the starter origin is not a blanket declaration for additions.

Keep related sentences, paraphrases and spelling variants in the same family
and split. Do not copy frozen test examples into either file. Validation rejects
cross-split families, normalized spellings (including umlaut aliases and spelling
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

## Setup and run

Run from the repository root with Python 3.12 and the documented Rust toolchain.
On macOS the official LightGBM wheel requires OpenMP (`brew install libomp` if
missing). See the [official installation guide](https://lightgbm.readthedocs.io/en/stable/Installation-Guide.html#macos).

```sh
python3 -m venv .venv/lambdarank
.venv/lambdarank/bin/python -m pip install -r scripts/lambdarank/requirements.txt
cargo build --release --locked -p si-cli

python3 scripts/lambdarank/pipeline.py validate
python3 scripts/lambdarank/pipeline.py prepare \
  --lexicon target/si-data/main.silex \
  --grams target/si-data/words.sigram --pinyin-correction \
  --output eval/lambdarank/prepared/starter-v3

.venv/lambdarank/bin/python scripts/lambdarank/pipeline.py train \
  --bundle eval/lambdarank/prepared/starter-v3 \
  --output eval/lambdarank/runs/starter-v3

.venv/lambdarank/bin/python scripts/lambdarank/pipeline.py evaluate \
  --bundle eval/lambdarank/prepared/starter-v3 \
  --run eval/lambdarank/runs/starter-v3 \
  --output eval/lambdarank/runs/starter-v3/recheck.json
```

`--grams` is optional for lexicon-only experiments; use the same resource pair
when comparing runs. `prepare` also accepts `--train`, `--validation` and
`--binary`. After changing data or Rust code, build and prepare a **new** snapshot,
then use a new run directory. Commands refuse to overwrite previous artifacts.
Do not manually edit a prepared bundle; checksum checks reject changes. Raw
source examples remain editable without affecting existing prepared snapshots.

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

Protocol v1 exports the first **64 eligible complete, noncompletion dictionary
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

Explicit `--user-lexicon PATH --user-grams PATH --user-snapshot-note TEXT` supports
an immutable user snapshot that predates **every** training/validation request.
The note documents that provenance; the tool cannot establish historical timing.
Never use a profile containing the target submissions. Resources are hashed before
and after export. No live profile discovery or automatic history training occurs.
Existing authored data has no user snapshots, so it cannot establish personalization
quality. Synthetic fixtures verify user calculations independently.

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
