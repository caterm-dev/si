# Candidate ranking architecture

## App routes

| App setting | Synchronous resolution | Full background result |
| --- | --- | --- |
| Pinyin correction off (default) | Full contextual statistical order | The same full statistical search and order |
| Pinyin correction on | Statistical search with the selected correction sensitivity | Calibrated LambdaRank with a six-bit reorder limit |

The default route skips model loading and the separate preview worker. It
keeps the exact spelling available while the first full result is pending.
The correction route can show a statistical preview while the full worker
finishes. The worker scores ordinary and corrected candidates, applies the
calibrated correction margin, then passes the pool to Swift's reorder limit.
Within the same complete-input span, scored members within 6 bits of the
statistical leader can take their model order. Statistical candidates
outside the band retain their order. Explicit priorities, unscored slots,
and exact literal fallback remain available.

Launch with `SI_USE_LEGACY_RANKING=1` to restore the unrestricted background
route. The Pinyin-to-text generator defaults off, independently of the route.
`SI_USE_PINYIN_MODEL=1` is a development opt-in on model-ranked requests.
The 61-feature model layout is fixed. With P2T disabled the source
flag is zero and its beam rank is missing. Secure and direct input skip
model inference.

## Statistical score and presentation

S is the lexical score in bits plus the preceding-field adjustment and
eligible personal preference. The preference combines the larger of the
whole-input and length-weighted token contributions and any eligible
previous-word contribution. The separate input-coverage reward is outside S.
Explicit pins and remembered whole-input choices have policy priority.
Complete results precede partial results, and partial results use the
consumed span when comparing their scores.

The Swift window filters undisplayable glyphs and retains the two highest
displayable S candidates in their incoming positions. Both remain selectable
and their incoming ranks determine placement. Constructed results
and completions normally qualify through the first four non-correction
choices. There are up to 27 ordinary slots and nine ordinary word slots.
Displayable exact Chinese dictionary characters also remain pageable.
Language-aware identity and the exact literal are preserved. Corrections
require explicit selection, and the initial highlight may skip a correction
even when it has the first displayed position.

## Exact terminal-completion pruning

- `1de758e` bounds a word's probability by the larger of its unigram prior
  and its largest observed continuation fraction across active histories.
  Each base smoothing step is a convex combination of the previous prior
  and the continuation fraction. The bound keeps the lexical token and
  completion costs, omits the nonnegative language switch cost, and rounds
  conservatively. A descending bound scan identifies completions that can
  never enter any relevant full beam. A candidate-level check uses the live
  beam and the same contextual and token bonuses as the ordinary gate.
- `b87cc2c` also sorts prefix eligibility within destination beam floors.
  The adjusted score at the bottom of a full destination beam cannot
  decrease. Subtracting the largest possible field adjustment yields a
  lower bound for the raw floor used by the eligibility check. The
  remaining prefixes can be excluded once a word's upper bound falls short.
  Strict inequalities preserve equal-scoring paths. Surviving edges and
  paths retain their original insertion order, including confirmation
  evidence and ties.

Output-sensitive terminal preferences retain the ordinary scoring checks.
User-corpus interpolation uses the original completion traversal.
Beam widths, candidate limits, dictionary branches, score formulas and
selection behavior are unchanged.

## Evaluation and performance

Use an empty personal profile and correction off as the primary evaluation.
Run the same 185 development queries with conservative correction for the
secondary evaluation. Authored prior choices are a separate test slice.
The [regression protocol](../eval/regression/README.md) records the settings
and the 17 individual ranks.

| Correction off, empty profile | Pure S Top-1 / Top-4 | Unrestricted LTR | X=6 |
| --- | ---: | ---: | ---: |
| 138 clean queries | 101 / 118 | 84 / 110 | 103 / 122 |
| 26 context queries | 9 / 14 | 14 / 24 | 13 / 18 |
| 17 regressions | 15 / 16 | 14 / 15 | 16 / 17 |

With conservative correction, X=6 scores 133 / 155 on the 185 queries,
103 / 122 on the clean subset, and 30 / 33 on the correction subset.
The S leader disappears zero times. With the default route, the first
synchronous and full background choices agree at every tested prefix.

Each optimization was compared with `ac2fb6b`. Candidate identity, pool
order, score bits, and actual Swift window order matched across 1,488
prefix records per correction setting. The records cover all 185 queries
and 17 regressions and include both empty and authored preferences where
the inputs differ. An additional 57,069 Rust prefixes from 5,000 distinct
stratified generated spellings matched at the candidate and score level.
That differential uses spelling and language settings without references.

MacBook Pro (Apple M3 Max), Release synchronous full search and Swift
window, empty profile and correction off. Times are milliseconds.

| Buffer length | Baseline p50 / p95 | Completion pruning p50 / p95 | Completion and prefix pruning p50 / p95 |
| --- | ---: | ---: | ---: |
| 1–2 | 2.61 / 9.48 | 2.63 / 9.27 | 2.57 / 9.20 |
| 3–5 | 38.14 / 111.83 | 5.45 / 13.30 | 4.84 / 11.24 |
| 6–10 | 75.24 / 170.82 | 6.47 / 12.80 | 5.65 / 10.17 |
| 11+ | 98.85 / 195.19 | 11.12 / 20.78 | 10.24 / 16.85 |

The main-thread resolution path stays in place for an explicit action when
the full result is still pending. A direct in-process run of
`InputSession.resolveCandidates()` and Swift window selection over 1,357
prefixes measured p95 / maximum of 11.17 / 27.90 ms with correction off and
12.30 / 29.38 ms with conservative correction. Native host queuing and
painting are outside the measurement. These timings apply to the base
dictionary. Performance with a populated user corpus remains unmeasured.

## Known limits and follow-up

- Diagnose the installed two-tree LTR using the early-stopping run, feature
  use and reference positions (C1–C3). Compare with the 185-query reranking
  model in a separately approved training experiment.
- Audit reference labels and distribution in the 200k base and 60k
  ambiguity datasets. Keep the label-v2 proposal separate until approved.
- Revisit the union gate using the existing bilingual and correction
  controls.
- Measure native preview delivery and evaluate a wait window for
  synchronous and background consistency, including navigation and stale
  request handling.
- Improve homophone and preceding-context evidence. The gain-weight and
  short-suffix ideas still need empty-profile evaluation and a separate
  authored-preference check.
