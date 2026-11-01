# Chinese candidate-ranking challenge

`chinese-v1/` is a frozen, AI-assisted SI-authored challenge with **1,230 cases,
337 distinct anchor scenarios and 171 connected spelling/contrast families**.
The development split has 299 cases; the test split has 931. Derived variants
are correlated and must not be described as 1,230 independent observations.
The earlier three-row `example.jsonl` remains a workflow fixture.

## Run the trained checkpoint

Scripts use the existing `small-character-v1/best.pt`, shared environment and MPS
defaults. They do not train or change the checkpoint.

```sh
cd /Users/eric/src/si

# Use development results to choose scoring settings or compare experiments.
./llm/reranker_small/scripts/evaluate_suite.sh --split dev \
  --output llm/reranker_small/reports/small-character-v1/chinese-v1-dev.json

# Run test after fixing model/scoring choices.
./llm/reranker_small/scripts/evaluate_suite.sh
```

The test report is
`llm/reranker_small/reports/small-character-v1/chinese-v1-test.json`.
Repeated evaluation refuses existing reports; pass `--output NEW_PATH`.
`--checkpoint PATH` selects another run's checkpoint or inference export.
If that checkpoint used a different training dataset, clean metrics are withheld
until its own overlap audit is available; all-case results remain labeled.
Do not use this challenge as training data or tune against the test answers.

Read these fields separately:

- `clean_by_track.controlled`: semantic/usage contrasts with authored candidate
  order. The baseline here is a synthetic rotation, not SI's engine ranking.
- `clean_by_track.decoder`: actual first-32 eligible full candidates, retaining
  engine order. Compare `top1_accuracy` with `baseline_top1_accuracy`, plus
  `wrong_to_correct` and `correct_to_wrong`.
- `candidate_recall` and `top1_when_gold_available`: distinguish retrieval
  failures from ordering failures. Correct answers are never added to decoder
  pools. The test decoder pool contains gold for 238/254 anchors, so its top-1
  ceiling is 238/254 even with perfect reranking.
- `top_k_accuracy`, `mrr`, `macro_family_top1` and `all_correct_families`: inspect
  ordering beyond first place and avoid letting large families dominate.
- `clean_by_category`: locate domain-specific gains and regressions.
- `all_by_track.robustness.policy_failures`: check abstention and exact-order
  policies separately from semantic accuracy.

Case records contain IDs, index orders and scores, without copying text into
reports. Find the corresponding ID in `dev.jsonl` or `test.jsonl` to inspect an
error. Timing includes the first cold case and measures offline scoring only.

## Coverage

| Track | Cases | Purpose |
| --- | ---: | --- |
| `controlled` | 337 | Same-spelling contrasts, full phrases/sentences, mixed text and multiple acceptable answers |
| `decoder` | 337 | Actual SICore pools; empty and missing-gold pools retained |
| `long_context` | 250 | Long paragraph prefixes with a recent disambiguating clause |
| `phrase` | 250 | Put the disambiguating clause inside the candidate; text-only phrase contrasts |
| `decoder_alias` | 8 | Real `ü`/`u:` queries alongside the `v` spelling family |
| `missing_gold` | 33 | Deliberately removed answers, verifying recall-failure accounting |
| `robustness` | 15 | Unicode, equal bytes, punctuation, pool limits and overlong-candidate abstention |

There are 23 category labels: daily, civic, science, technology, education, work,
finance, travel, health, shopping, names, food, grammar, sentence, pronoun, mixed,
segmentation, umlaut, idiom, negation, numeral, polyphone and robustness.

Examples include 权利/权力, 时间/实践, 北京/背景, 的/地/得, 在/再, 西安/先,
重庆/虫情, 不行/步行, 一千/以前, idiom orthography, explicit fictional names,
Swift/SQL/HTTP/API, file paths, digits and C++. Multiple references accept declared
variants such as 预订/预定. Orthography items intentionally prefer conventional
written forms; these are authored usage judgments, not independent annotation.

Diagnostic Unicode cases cover composed/decomposed accents, supplementary Han,
emoji/ZWJ, traditional forms, punctuation and identifier casing. A pool with a
candidate over the model context must abstain and retain its original order.
Those cases, and deliberately missing answers, are excluded from clean quality
metrics. The scorer's own context limit can make a smaller model abstain on more
items; inspect abstention counts when comparing architectures.

## Construction and audit

`lexical.tsv` and `additional.jsonl` are reviewable authored sources. Semantic
labels were written before scoring the trained checkpoint. No private typing,
personal learning archive, clipboard or external benchmark was read. A spelling
check against the maintained Chinese dictionary validates all 337 anchors and
their candidate readings; it does not independently validate semantic labels.

Families connect both normalized Pinyin inputs and shared lexical substitutions.
For example, 权利/权力 in a short query stays with the same contrast wrapped in a
sentence. Mixed 使用/食用 variants and `v`/`ü`/`u:` aliases also stay together.
The seeded hash assigns entire connected families to dev or test. Generic
construction templates still occur in both splits, so this is not a claim of
independent natural-user sampling.

An exact normalized context-plus-reference substring audit scanned the existing
prepared dataset: 1,394,936 training documents, 28,940 validation documents and
14,526 test documents. No anchor match was found. Normalization applies NFKC,
case folding and whitespace collapse, with a minimum pattern length of eight
characters. This checks novel complete contexts, not unseen words; common words
and idioms can occur in pretraining. It cannot rule out paraphrases or wider
Web overlap. An anchor matching any prepared split is excluded from clean
metrics along with all its derived variants. `overlap-audit.json` pins document
hashes and the dataset ID, which evaluation checks against the model.

`SICandidateExport` uses the same SICore as the app. Both languages are enabled,
with no personal phrases/learning and fixed time. It retains the first 32 whole,
nonliteral candidates after excluding prefixes, English completions, punctuation
and unrecognized literal spans. This is the full-candidate research protocol,
not the app's 27-item presentation shortlist. Language-aware candidate identities
are retained even for identical text. Literal availability is checked outside
LM ordering. All 197 query snapshots are frozen in `decoder-snapshots.jsonl`.
Resource/code hashes, source licenses and construction modifications are retained.

Reproduce into a **new directory**, never over the frozen version:

```sh
swift build --scratch-path .build/swift --configuration release --product SICandidateExport
./llm/.venv/bin/python -m llm.reranker_small.benchmarks.build \
  --output /tmp/si-chinese-v1-reproduction \
  --exporter .build/swift/release/SICandidateExport \
  --audit-data llm/reranker_small/data/prepared/small-character-v1

./llm/reranker_small/scripts/check.sh -p test_benchmarks.py
```

Without `--audit-data`, the build is explicitly unaudited and clean metrics are
withheld. The committed manifest pins the distributed files; regression checks
also reproduce cases from the authored sources and frozen decoder snapshots.

This is a broad constructed challenge, not an independently human-annotated
production benchmark. Labels still need outside review. Prefix/whole scoring,
cross-language calibration, personal vocabulary, literal selection, host events
and live keystroke latency require separate integration evaluation.
