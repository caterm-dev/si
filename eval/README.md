# Shared SI evaluation

This directory owns the public, model-independent evaluation data. Small and
large models, the SICore engine and other algorithms must use the same frozen
task/suite/split and scoring protocol when comparing results. Model training,
checkpoints and token-loss/perplexity validation remain under `llm/`.

| Task | Frozen suite | Dev cases | Test cases | Scope |
| --- | --- | ---: | ---: | --- |
| [ranking](ranking/README.md) | `chinese-v1` | 299 | 931 | Fixed candidate ordering, contextual contrasts, real decoder pools and robustness |
| [correction](correction/README.md) | `synthetic-v1` | 25 | 55 | Noisy Pinyin, Hanzi/English/mixed correction and exact-preservation controls |
| [pinyin_to_hanzi](pinyin_to_hanzi/README.md) | `lexical-v1` | 69 | 64 | Character/short-word conversion, with multiple accepted homophones |

These are constructed regression suites, **not independently reviewed production
benchmarks**. Ranking's 1,230 cases share 337 anchors and correlated derived
tracks. Pinyin's 133 input cases represent 142 existing CSV pairs after grouping
same-input accepted outputs. The dev/test assignments are fixed. Existing test
results have already been inspected; moving files does not make a fresh holdout.
Correction is an initial 80-case authored fixture, not broad correction coverage.

## One workflow for every model or algorithm

Run from the repository root. Validation/export/scoring/comparison use Python's
standard library only; they do not load a model or start training.

```sh
python3 -m eval validate

# Export model inputs, without reference answers, categories or expected policies.
python3 -m eval export --task ranking --split dev \
  --output eval/requests/ranking-dev.json

# A reproducible baseline also demonstrates the prediction-file format.
python3 -m eval baseline --task ranking --split dev \
  --output eval/predictions/baseline-dev.json
python3 -m eval score --task ranking --split dev \
  --predictions eval/predictions/baseline-dev.json \
  --output eval/reports/baseline-dev.json
```

For a large reranker or a new algorithm, read the exported request, run your
predictor locally, and write a prediction file using the protocol below. No
small-model checkpoint, tokenizer, architecture or training dataset is required.
Use `--task correction` or `--task pinyin_to_hanzi` for the other tasks.
Every command refuses to overwrite an existing output; use a new filename.

The existing model adapters are optional and use the shared PyTorch environment:

```sh
./llm/.venv/bin/python -m eval.adapters small --task ranking --split dev \
  --checkpoint llm/reranker_small/runs/small-character-v1/best.pt \
  --device mps --output eval/predictions/small-dev.json
python3 -m eval score --task ranking --split dev \
  --predictions eval/predictions/small-dev.json --output eval/reports/small-dev.json

./llm/.venv/bin/python -m eval.adapters converter --task pinyin_to_hanzi --split dev \
  --checkpoint llm/pinyin_to_text/runs/small-pinyin-lexical-v1/best.pt \
  --device mps --beam-size 5 --output eval/predictions/converter-dev.json
python3 -m eval score --task pinyin_to_hanzi --split dev \
  --predictions eval/predictions/converter-dev.json --output eval/reports/converter-dev.json

python3 -m eval compare eval/reports/baseline-dev.json eval/reports/small-dev.json \
  --output eval/reports/ranking-dev-comparison.json
```

The converter adapter also supports `--task correction`; this only evaluates its
outputs and does not imply that a particular checkpoint learned correction.
Its actual generated outputs are evaluated without adding a literal fallback.
The large model is not implemented yet; its future predictions use exactly the
same ranking inputs and scorer. The legacy small-model `evaluate_suite.sh`
command still works through compatibility links to this one canonical dataset.
Its historical report format remains separate from unified reports.

## Data and prediction protocol (version 1)

Cases are UTF-8 JSONL in `<task>/<suite>/{dev,test}.jsonl`. Shared fields are:

| Field | Meaning |
| --- | --- |
| `id` | Stable unique case ID within a suite |
| `family_id`, `split` | Related-case grouping and fixed dev/test assignment |
| `input`, `context` | Original input and preceding context; ranking diagnostics may have null input |
| `references` | Nonempty list of accepted exact output strings |
| `track`, `category`, `diagnostic` | Reporting groups and separation of policy diagnostics from quality |
| `candidates`, `candidate_details` | Ranking-only ordered pool and, when available, language-aware identities |

To produce predictions, retain `schema_version`, `task`, `suite`, `split` and
`dataset_sha256` from the exported request; replace `cases` with `predictions`
and add a `predictor` object. This complete Python example runs on a blind
request and produces a baseline that can be replaced by a new model:

```python
import json

with open('eval/requests/ranking-dev.json', encoding='utf-8') as handle:
    request = json.load(handle)
cases = request.pop('cases')
request['predictor'] = {'name': 'my-algorithm', 'revision': 'v1', 'config': {}}
request['predictions'] = [
    {'id': case['id'], 'order': list(range(len(case['candidates']))), 'abstained': False}
    for case in cases
]
with open('eval/predictions/my-algorithm-dev.json', 'x', encoding='utf-8') as handle:
    json.dump(request, handle, ensure_ascii=False)
```

Ranking predictions use a **complete permutation of zero-based candidate
indices**. Never deduplicate by text: equal text from different languages keeps
distinct indices. Do not insert gold answers, retrieve extra candidates, remove
missing-gold/empty pools, or alter the frozen engine order. An abstaining model
must set `abstained: true` and retain the original order. Diagnostic policies
such as context-limit abstention remain visible separately; they reflect the
original small-model protocol, not a universal context limit for larger models.

Correction and Pinyin predictions instead use `{"id": "...", "outputs": ["..."]}`:
an ordered list of up to 32 distinct exact outputs, or `[]` for no prediction.
Multiple acceptable reference strings are supported. No case, whitespace,
punctuation, Unicode normalization or Pinyin alias normalization is applied to
output scoring. Include the complete output, not a label or explanation.

`predictor.name` is required. Record algorithm/code revision, checkpoint SHA-256,
decoding/scoring configuration and training dataset identity for reproducibility.
Adapters fill in checkpoint and runtime metadata. Every case must appear exactly
once; missing/extra/duplicate cases, invalid permutations and mismatched
dataset/split identities fail scoring rather than silently reducing the denominator.

## Metrics and fair comparisons

- Ranking: top-1/top-k, MRR, original-order baseline, candidate recall, top-1
  conditional on gold availability, newly correct/wrong counts and family macro.
  Keep controlled/decoder/derived tracks separate; there is no pooled ranking
  headline score. The frozen first-32 decoder protocol differs from the app's
  27-item shortlist and has retrieval failures even with perfect ordering.
- Generation: exact top-1/top-k, MRR, family macro and corpus character error
  rate (Levenshtein over Unicode scalars, choosing each case's reference with
  minimum normalized distance). Failed/empty predictions count as errors.
- Correction additionally reports accuracy on cases needing changes and the
  overcorrection rate on cases whose original text is accepted. The same fields
  are available for Pinyin, where the unchanged subset may be empty.
- Diagnostics are excluded from quality groups and reported separately. Reports
  contain IDs, orders and numeric results, not copies of case or output text.
- Comparisons require identical task, suite SHA-256, split, full coverage and
  scorer SHA-256. There is no single combined score across different tasks.

The retained ranking overlap audit applies only to the dataset ID named in its
provenance. Clean metrics are withheld for another or undeclared training
dataset. Arbitrary future models must audit their own corpora; the same test
file alone does not establish absence of leakage. Full results remain available
and explicitly separate from the audited subset. Correction/Pinyin have no
general model-corpus overlap audit. Dev is for selecting settings; do not train
on these suites or choose models/settings against test answers.

## Maintenance, privacy and validation

`catalog.json` registers task defaults and pins each suite manifest SHA-256.
Manifests pin data, attribution and source bytes; validation reads both splits,
checks hashes, unique IDs, family separation and generation input/reference
overlap. Adding coverage or changing a label/pool/split requires a **new suite
version**, an explicit catalog/default update, provenance and new reports.
Never refresh frozen decoder pools just because the engine changes. Export
current-engine predictions separately; it cannot silently replace this pool.

Ranking data was relocated byte-for-byte, retaining its manifest, notices,
licenses and source snapshots. Pinyin bundles the exact four original held-out
CSVs with their hashes and provenance. Correction is SI-authored under
GPL-3.0-only, as is the framework; ranking's derived decoder text retains its
existing Wanxiang attribution. See per-suite provenance and the repository
[license](../LICENSE). No new external data, dependency or network access is used.

Keep generated requests/predictions/reports in their ignored directories here.
`eval/private/` is also ignored; public suites must never contain personal
phrases, Input History exports, clipboard/host text or private model output.
No export, inference or evaluation command transmits data or starts training.

```sh
python3 -m eval validate
python3 -m unittest discover -s eval/tests -p 'test_*.py' -v
./llm/.venv/bin/python -m unittest discover -s eval/tests -p 'test_*.py' -v
./llm/reranker_small/scripts/check.sh -p test_benchmarks.py
```

The standard-library run skips optional PyTorch adapter tests if PyTorch is
unavailable. The shared environment executes real tiny-checkpoint adapter tests.
Offline results do not verify InputMethodKit routing, native UI or host latency.

Verified on November 3, 2026: all three suites passed integrity validation; all
13 shared evaluation tests and five legacy ranking tests passed, including real
tiny-checkpoint adapters. The existing 30,000-step small checkpoint completed
all 299 dev ranking cases, and the local converter completed all 69 lexical dev
cases through the unified adapter/scorer. Baseline workflows for all tasks and
the common report comparison also ran successfully. The repository's 307 Swift
tests and Debug app build passed. Generated predictions/reports stay ignored;
no training, installation or host-app verification was performed.
