# Offline LambdaRank starter experiment

This is an offline experiment, not an app model. Python trains LightGBM; the
Rust engine exports real candidates and versioned features. No model is loaded
by SI, and conversion, search limits, learning and automatic confirmation are
unchanged. Future Rust inference can load the trained model through a separately
reviewed integration.

## Data and scope

- `train.jsonl`: 88 authored queries, used for fitting.
- `validation.jsonl`: 42 separate authored queries, used for early stopping and
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
  --grams target/si-data/words.sigram \
  --output eval/lambdarank/prepared/starter-v1

.venv/lambdarank/bin/python scripts/lambdarank/pipeline.py train \
  --bundle eval/lambdarank/prepared/starter-v1 \
  --output eval/lambdarank/runs/starter-v1

.venv/lambdarank/bin/python scripts/lambdarank/pipeline.py evaluate \
  --bundle eval/lambdarank/prepared/starter-v1 \
  --run eval/lambdarank/runs/starter-v1 \
  --output eval/lambdarank/runs/starter-v1/recheck.json
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

`si-cli rank-features BASE [--grams GRAMS]` reads one TSV request per line:
hex-encoded UTF-8 source, hex-encoded UTF-8 context, enabled-language list. Output
starts with a schema/name header; each row is language, hex output, comma-separated
float features, followed by `END<TAB>total_eligible` for every request. This keeps
newlines/tabs and Unicode exact without adding a serialization dependency.

The shared Rust `ranking_features` module defines `si-rank-features-v2` with
38 features. Its first 12 columns retain their v1 meanings for controlled
comparisons and compatibility with existing models:

| Feature | Meaning |
| --- | --- |
| `lexical_bits` | Existing lexical path score |
| `context_bits` | Existing transient preceding-context adjustment |
| `effective_bits` | Sum of those two scores, with empty personal state |
| `consumed_scalars`, `output_scalars` | Unicode scalar counts, not UTF-16 offsets |
| `lexical_tokens` | Existing candidate lexical-unit metadata |
| `bits_per_source_scalar`, `bits_per_output_scalar` | Lexical score divided by lengths |
| `is_chinese`, `is_english`, `is_mixed` | Language indicator features |
| `separator_count` | Explicit ASCII apostrophes in consumed source |

The added groups capture evidence from the exact scoring derivation:

| Group | Added features and units |
| --- | --- |
| `score_components` | Unigram log probability, internal gram adjustment, token/language/spelling costs, all in bits. Positive costs subtract from the lexical score. Spelling cost includes the existing abbreviation penalty. |
| `gram_evidence` | Fraction of path tokens with an observed gram, highest observed order, sum of `ln(1 + count)` for each token's highest-order observed gram, and whether a gram resource was loaded. Zero-count smoothing contexts do not count as observed hits. |
| `context_evidence` | Whether nonempty preceding text was supplied, effective same-language history length, an observed first-word gram flag, its highest observed order and log support. These use the engine's existing last-sentence selection and segmentation. |
| `path_structure` | Actual best-path token count, independent exact direct-match flag, single-Han-character token count, minimum/maximum token scalar length and language-switch count. |
| `spelling` | Abbreviated lexical-node count, canonical Pinyin syllable count, consumed explicit separator count, normalized input-unit count, lexical bits per normalized unit, and separators coinciding with word boundaries. |

`best_path_tokens` stays with the derivation supplying `lexical_bits`. The legacy
`lexical_tokens` column retains presentation semantics, where an alternative
direct dictionary match may mark a candidate as one token. `has_direct_match`
records this independently, even when a composed derivation supplies the score.
The five score components reconstruct the lexical score within floating-point
tolerance. Preceding-context adjustment remains separate.

Normalized input units come from the engine's existing grapheme/source mapping,
so `ü`, decomposed `u` plus diaeresis, `u:` and `v` share a unit count. Pinyin
syllable count comes from the selected lexical readings, including abbreviated
nodes. Separator placement is constrained by lookup; word-boundary separators
can distinguish different valid segmentations of the same source.

Evidence capture uses `CandidateEngine::candidates_with_evidence` and is enabled
only for base-resource engines. User-resource engines return candidates without
this offline evidence. Ordinary conversion does not allocate scoring-evidence
objects. Tests compare complete candidate results after removing diagnostics,
including scores, source boundaries, confirmation evidence, order and bytes.

No reference, selection position, label or future suffix enters the feature
vector. Python validates the Rust header. Existing v1 prepared bundles and runs
remain readable by training and evaluation. New preparation produces v2. Feature extraction rejects nonfinite
values; schema/order must be versioned whenever meanings change. Inference ties
retain baseline order. Model scores are not probabilities or lexical bits, and
must not be substituted into app automatic-confirmation thresholds.

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
  --bundle eval/lambdarank/prepared/features-v2-expanded \
  --output eval/lambdarank/runs/features-v2-comparison
```

This trains 12 variants: `v1`, `all`, each `add_GROUP` on top of v1, and each
`without_GROUP` from the full feature set. Group names are listed above.
`comparison.json` includes all validation metrics, per-category and per-query
results, feature importance and the bundle hash. Each child run retains its
model and versioned metadata. Training and early stopping defaults are identical
across variants. The validation set is development evidence for these comparisons.

To train one selection, pass `--feature-set v1`, `--feature-set all`, or a group
variant to `train`. `evaluate` automatically uses the model's stored feature
selection. The default is `all` for experimenting with the complete v2 schema.
New features require a v2 bundle. Existing v1 bundles support `all` and `v1`.
Feature importance records split count and gain; assess additions through the
paired comparisons rather than interpreting training gain as quality improvement.

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
