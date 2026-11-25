# Candidate ranking architecture

## App conversion

Each edit completes full conversion before the window updates.
The application loads the paired lexicon and word-gram snapshots before
opening its IMKServer. Pinyin correction is enabled by default and adds bounded
single-edit suggestions that meet the conservative statistical confidence margin.
Whole spelling suggestions, completions and ordinary whole results share the
same score order. Secure input suppresses suggestions, and direct input passes
keys through.

## Local model ranking

**Local model ranking** is a separate Typing option enabled by default. With it on,
Rust evaluates the first 12 eligible ordinary whole-input candidates in statistical
order, without a score-gap cutoff. Completions, literal segments,
personal phrases and spelling corrections receive no model reward. Each
candidate can use up to 12 model tokens, sharing up to 16 trailing context
tokens from the current punctuation-delimited fragment. A terminal boundary
clears the previous fragment for model ranking too. Empty context works at
the start of a field.

Let `r_i` be the character model's mean natural-log probability per output
scalar, and `r_max` the highest score in the scored pool. The model gap is
`d_i = (r_i - r_max) / ln(2)` bits. With `lambda = 0.8` and `C = 8`, Rust
adds the nonnegative reward `lambda * (C + max(d_i, -C))` after statistical
search. The strongest model result receives 6.4 bits; results at least 8
model bits behind it receive zero. Differences within that range are preserved,
and adding a worse model outlier cannot change existing rewards. This is a
common 6.4-bit offset from the signed adjustment `lambda * max(d_i, -C)`
within the scored pool. Unscored candidates retain zero reward, so the two
forms are equivalent only when comparing scored candidates with one another.
Rust preserves deterministic ties. The shared Rust presentation policy carries
the reward into final ordering and retains the original statistical scores
for the shortlist.
The defaults come from `[local_model_ranking]` in [config/si.conf](../config/si.conf):
`model_score_weight = 0.8` and `model_score_gap_limit_bits = 8`. Rust embeds this file at build time;
`SmallReranker::open` captures the validated parameters when the model loads.
Changing the source configuration requires rebuilding and reinstalling the app.
Library callers can read an explicit `SiConfig` and pass its `engine.local_model_ranking` to
`SmallReranker::open_with_config` without recompiling. Pool size, context tokens
and candidate tokens also come from that section. The limits are 1..64 candidates,
0..128 context tokens and 1..64 candidate tokens. Pools with fewer than two
eligible distinct outputs skip scoring. The CLI's `candidates` command still
does not run the character model. Omitted engine sections retain bundled defaults;
an explicitly supplied section requires all its keys. Reward weight accepts
0..4 and gap limit 0..32 bits; either can be zero to disable model rewards.
No configuration files are read during conversion.
An exact remembered choice retains priority. If the model changes the
leading whole candidate, that result cannot trigger prefix auto-confirmation.

The app loads the packaged small FP32 model once at startup and shares it
with user-dictionary snapshots. Secure input and provisional preview skip
inference. Missing or invalid weights, an unscorable pool or inference errors
use the statistical results. All scoring runs locally and transiently.
[Model provenance](../Data/RerankerSmall/README.md)

An in-process Release comparison on macOS 27.0.1 arm64 used the original
four-candidate limit, two-bit margin and 0.5 model weight, with empty personal
state and correction off. The paired
snapshots had SHA-256 prefixes
`bd590908fc4a` (lexicon) and `7f50295ba035` (word grams). With the same
decoded pools and Swift shortlist, enabling the model raised first-choice
hits from 196 to 211 across 458 authored context queries. The 220 compact
queries without context had 160 first-choice hits in either mode. Across
5,585 typing-prefix conversions from the compact queries, median time went
from 10.3 to 10.6 ms and p95 rounded to 31.3 ms in both modes. All queries
retained the full engine candidate identities and exact original spelling.
These authored fixtures do not establish native host latency or representative
ranking quality.
[Evaluation fixtures](../eval/README.md)

With the same snapshots and two-bit margin, increasing the model pool from
four to eight scored additional candidates for 22 of the 678 complete queries.
First-choice hits went from 211 to 210 on the contextual queries and remained
160 on the compact queries. On a 1,403-edit sample from the compact queries,
in-process p95 went from 32.3 to 32.2 ms.

## Statistical score and presentation

Confirmed fragment starts use the base `<s>` grams. Fragment boundaries match
offline ingestion: explicit delimiters and line endings start a new fragment;
book-title marks, quotes and brackets preserve adjacency and cannot establish
a sentence start on their own. Wrappers after a delimiter preserve the new
start. Other symbols break adjacency without establishing sentence start.
Periods inside ASCII words/numbers, including domains and decimals, are not
sentence delimiters. Missing
host text is distinct from a confirmed empty prefix. The longest countable
candidate prefix beginning with `<s>` supplies its raw observation count `c`.
The comparison uses `r = c/max(c_competitors)` for enabled dictionary paths
consuming the same source span. This equals the ratio of their start
probabilities because the global denominator cancels. The reward is
`2*r*r*(3-2*r)` bits: the highest observed opening receives two bits, equal
maxima tie, and unseen openings receive zero. Corpus-wide count scaling and
unrelated input spellings do not affect rewards. Exact, completion and
corrected spelling paths compare separately; personal/verbatim paths are
excluded. Maxima are prepared before lexical beam pruning by a request-local
traversal bounded to 8,192 states and 65,536 transitions; exhaustion disables
start rewards only for later unfinished spans, preserving completed-prefix
maxima. This stage neither changes ordinary
word frequencies nor introduces a penalty. A longer supported boundary gram
replaces the shorter one's count rather than stacking rewards. Beyond the
highest stored order, the opening-prefix count stays fixed; its reward uses
the competitors at the current consumed span. Personal/verbatim
paths receive no field adjustment. Prefixes use their consumed words only;
no sentence end is inferred from candidate completion. User ingestion remains
unmarked.

S is the lexical score in bits plus the preceding-field adjustment and
eligible personal preference. The preference combines the larger of the
whole-input and length-weighted token contributions and any eligible
previous-word contribution. The separate input-coverage reward is outside S.
Explicit pins and remembered whole-input choices have policy priority.
Complete results precede partial results, and partial results use the
consumed span when comparing their scores.

The Rust presentation policy shortlists candidates without checking system font
coverage or reserving statistical leaders. Constructed results qualify only in
the original first four ranked positions. The leading constructed output length
then sets their shared limit: fewer than six nonwhitespace graphemes allows four
choices, six allows three, seven/eight allows two, and nine or more allows one.
Whole sentences, multiword prefixes, corrections and dictionary completions use
the same budget, including completions from one dictionary entry. No score-gap,
relative-frequency or completion-stem display filter applies.

There are up to 27 ordinary slots and nine ordinary exact word slots. Generated
exact Chinese dictionary characters also remain pageable. Language-aware identity
and the exact literal are preserved. The first displayed candidate gets the
initial highlight. Space confirms the highlighted candidate.

## Preceding-text segmentation and reuse

Field scoring retains the best K distinct terminal histories (default 3), not
the first K raw segmentation paths. Duplicate histories retain only their best
path. Weights are proportional to `2^((s_i - s_max) / T)` with T=4 by default;
`[field_context]` in `config/si.conf` owns both settings. The engine averages
smoothed conditional probabilities, then takes log2. Ingestion remains single-best.
Caller-owned Rust caches reuse immutable preparation for the same final fragment
and resource/configuration instance. They do not cache candidates or model scores.
See [field-context architecture](ARCHITECTURE.md#rust-conversion) for search bounds,
base/user histories, lifecycle and privacy.

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
