# Candidate ranking architecture

## App conversion

Each edit completes full statistical conversion before the window updates.
The application loads the paired lexicon and word-gram snapshots before
opening its IMKServer. Turning on Pinyin correction adds bounded single-edit
suggestions that meet the conservative statistical confidence margin.
Ordinary whole results precede suggestions of the same span. Secure input
suppresses suggestions, and direct input passes keys through.

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
Language-aware identity and the exact literal are preserved. The first
displayed candidate gets the initial highlight. Space confirms the
highlighted candidate.

## Exact terminal-completion pruning

- `1de758e` bounds a word's probability by the larger of its unigram prior
  and its largest observed continuation fraction across active histories.
  Each base smoothing step is a convex combination of the previous prior
  and the continuation fraction. The bound includes the completion cost
  and rounds conservatively. A descending bound scan identifies completions that can
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

## Historical evaluation and performance

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

Before the switch to fully synchronous conversion, a direct in-process run of
`InputSession.resolveCandidates()` and Swift window selection over 1,357
prefixes measured p95 / maximum of 11.17 / 27.90 ms with correction off and
12.30 / 29.38 ms with conservative correction. Native host queuing and
painting are outside the measurement. These timings apply to the base
dictionary. Performance with a populated user corpus remains unmeasured.

## Cross-edit search caches

The November 22, 2026 follow-up reuses dictionary transition ranges between
keystrokes, including transitions explored by correction search. Cached
prepared word-gram contexts retain their continuation totals across requests.
Both caches belong to an immutable base/user resource pair, contain only
dictionary identities/ranges and have bounded capacity. They never retain a
client composition or a final candidate list. Concurrent requests compute
locally instead of waiting for a cache. Reloading the resources creates fresh
caches.

Sampling a Release long-input conversion identified repeated numeric-key
hashing in gram-context lookup as a major scoring cost. Those ID-only keys
now use a lightweight hash with full equality checks; candidate identity,
output comparison and committed bytes are unchanged. The bounded word-history
update uses a short shift instead of a general slice rotation. Fixtures
compare reused and fresh engines across edits, case, aliases, separators,
language settings, context, preferences, personal phrases and concurrent
requests. The lattice starts fresh on each request.

## Known limits and follow-up

- Measure native synchronous typing, deletion and candidate selection with a
  populated user corpus.
- Improve homophone and preceding-context evidence. The gain-weight and
  short-suffix ideas still need empty-profile evaluation and a separate
  authored-preference check.
