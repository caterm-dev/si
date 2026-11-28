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
order, without a score-gap cutoff. Completions, verbatim paths, personal phrases
and spelling corrections are not sent to model inference. Candidates use at most
16 model tokens and share up to 16 trailing context tokens from the current
punctuation-delimited fragment. A terminal boundary clears the previous fragment.

For the whole candidate string `c`, let
`s(c) = log P(c | context) / ln(2)` bits. The model sums complete-candidate token
log probabilities, preserving internal dependencies independently of lexical
segmentation, without dividing by output length. The final adjustment is
`w * clamp(s(c) - max_pool_score, -B, 0)`. Defaults are `w=0.8` and `B=8`.
The highest conditional probability gets zero; other scored candidates can lose
at most 6.4 bits. Unconditional probability is not subtracted: the retired lift
ratio could favor rare candidates with very low baselines. No auxiliary lift
reward is added.
After a valid pool is scored, ordinary whole-input candidates outside it receive
the lowest computed adjustment, including completions, corrections and outputs
beyond the model token/byte limits. If their exact text was scored under another
candidate identity, they reuse that score instead. Model work remains bounded to
the configured pool. Prefixes, original literals, personal phrases and verbatim
paths retain zero adjustment. No valid pool, an unavailable model or inference
failure preserves the complete statistical result set without model penalties.
The engine re-sorts the complete result set after applying these adjustments.
Base statistical scores, deterministic ties and explicit pin/remembered-choice
priority are preserved.

Empty/unavailable context, a zero context budget or a context truncated to zero
model tokens uses a separate BOS-only branch. The native inference path prepends
the tokenizer's BOS token; no textual sentence marker is inserted. Its complete
sequence log probability is summed over all model tokens, including byte fallback,
and converted to bits without dividing by output length. Let this score be `s(c)`.
The adjustment is `w * clamp(s(c) - max_pool_score, -B_sentence, 0)`, with
`B_sentence=8` and `w=0.8` by default. The highest model score gets zero;
other scored candidates can lose at most 6.4 bits. Adding a worse pool member
or a shared score offset does not change existing adjustments.
No EOS probability is added. This adjustment replaces conditional-probability scoring
for that request; ordinary unscored whole candidates use the same worst-pool policy.
Pools with fewer than two distinct eligible outputs skip scoring.

A model-owned 4,096-entry LRU caches unconditional sequence log probabilities
by exact candidate bytes. It never stores host context, typed source, preferences
or final candidate lists, and cannot inject candidates. No cache lock spans
inference; contention computes request-local baselines without waiting.
The cache stays in memory with the immutable model, is not persisted and is
released with that model. Reloading a model creates a separate cache.

Defaults come from `[local_model_ranking]` in [config/si.conf](../config/si.conf):
`model_score_weight = 0.8`, `model_score_gap_limit_bits = 8` and
`model_sentence_reward_cap_bits = 8`. The last key retains its historical name
but now bounds the BOS-only penalty before weighting. Rust embeds
this file at build time; rebuild and reinstall the input method to apply edits.
Library callers can read a validated `SiConfig` and use
`SmallReranker::open_with_config` without rebuilding. The section also controls
pool size (1..64), context tokens (0..128) and candidate tokens (1..64).
Weight accepts 0..4 and both bounds accept 0..32 bits. Zero weight disables both
branches; a zero gap limit disables contextual model adjustments, and a zero sentence cap
disables BOS-only adjustments. Missing whole engine sections retain bundled defaults; explicitly
supplied sections require every current key. Conversion reads no configuration
files. The CLI's `candidates --model <bundle>` runs the same character model.

At startup the app loads Small from FP32 and Large from FP16, and shares both
with user-dictionary snapshots. A request selects at most one model. Both use FP32 arithmetic. Secure input and provisional preview skip
inference. Missing or invalid weights, an unscorable pool or inference errors
use the statistical results. All scoring runs locally and transiently.
[Model provenance](../Data/RerankerSmall/README.md)

The following historical measurements used the former per-scalar BOS reward
and model weight 1.0, before the summed-score adjustment and 0.8 default.
On the 1,020-query authored recall suite, adding that branch to the
bounded-gram-backoff engine changed first-choice hits from 442 to 455
and Recall@9 hits from 756 to 762. Fourteen references became first and one
ceased to be first (`灯光师让我们站在白线内` became second behind
`灯光是让我们站在白线内`). Full-pool hits stayed at 839; this final reranking
does not inject candidates. These are regression measurements on local resources,
not an independent quality estimate. For `chiyoushijian` without preceding text,
`持有时间` receives +0.789539 bits and `吃有时间` +0.765877; their final scores
are -23.682805 and -23.908164 respectively. The model's preference between
these two is small; the gram-backoff change supplies most of their separation.

The historical measurements below used the original v1 checkpoint. The current
bundled selection and its isolated fixed-pool results are recorded in the
[model provenance](../Data/RerankerSmall/README.md).

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

## Offline k-best and scoring-pool inspection

`CandidatePoolInspector` and `si-cli candidate-pool` are offline diagnostic APIs.
Ordinary conversion keeps its original search, scores and candidate ordering.
The retired `--structure-diversity` experiment incorrectly applied a quota inside
beams; it is removed. Its historical 839-to-807 recall result describes that
retired search rule, not post-search pool selection.

The inspector loads no user profile or neural model. It prepares immutable
history-independent lexical upper scores once: for each base word, the maximum
of its unigram score and the existing rewarded score under every observed
bigram/trigram history. Missing-gram penalties can only lower this bound.
A backward acyclic Viterbi pass supplies optimistic suffix values. A* retains
full path histories and lazily refines suffix bounds with memoized actual gram
scores, keyed by source position, the last two base word IDs and the separate
sentence-opening state. Higher-order opening history is retained. If the bound
refinement budget is exhausted, the conservative lexical bound remains valid;
no partial maximum becomes a pruning threshold. A rounding allowance covers
bounded floating-point accumulation.

Completed enumeration certifies up to N distinct `(language, exact output bytes)`
whole candidates, ordered by the existing statistical score and deterministic
identity ties. All paths at the cutoff score must be resolved before certification.
The graph includes enabled Chinese, English and mixed full-spelling paths, source
separators and aliases, with the existing 128-unit and 4,096-byte constructed
bounds. Abbreviations, completions, corrections, personal and verbatim paths are
outside this exact graph; they remain in the independently preserved native pool.
Neither a wide beam nor an incomplete A* run is labeled a complete exact k-best.

The request accepts `--k-best` (1..512, default 256), `--pool-size` (1..64,
default 12), `--structure-limit` (0..2, default 2; 0 disables grouping),
`--multiword-limit` (0..pool size, default pool size) and `--search-budget`
(1..1,000,000 A* expansions, default 100,000). The frontier is bounded to 100,000
paths, the lexical graph to 65,536 edges, and suffix refinement to at most
100,000 cached states and `min(10*search_budget, 2,000,000)` transitions.
Exhausting input, edge, frontier or A* work limits reports an incomplete result
with zero certified entries; partial results remain explicitly provisional.

After enumeration, the inspector preserves the union with every native whole
candidate. It keeps the original native rank, score and model eligibility
separately. A stronger exact derivation may improve the union score; an exact
trace is never attributed to a stronger, different native derivation. Each row
reports its exact-path score and whether that trace matches the selected union
derivation. Untraced native derivations are exempt from structural/word quotas.

Pool selection runs in statistical order. Grouping requires a constructed path
with at least one fixed lexical anchor; direct characters/words and paths made
entirely of single-Han lexemes stay independent. A structural key includes language,
token source spans and exact non-single-Han token text, replacing each single-Han
lexeme with a wildcard. For example, `及 / 好 / 携带` and `机 / 好 / 携带`
share a key, while `几号 / 携带` and `及 / 好 / 鞋带` remain distinct. Grouping
keeps the first one or two paths without modifying any search state. Existing
ordinary model eligibility and the candidate byte precheck follow, then an
optional cap on paths with at least three lexical tokens, then the pool-size
limit. A restrictive quota can underfill the pool. Every exclusion is labeled
`ineligible`, `structure`, `length`, `word-quota` or `pool-limit`; structure
exclusions identify the retained competitors. These are selection diagnostics,
not neural scores: the actual model token bound and inference remain separate.

```sh
cargo build --release --locked -p si-cli
printf 'jihaoxiedai\n' | target/release/si-cli candidate-pool Data/Engine/main.silex --grams Data/Engine/words.sigram --k-best 256 --pool-size 12 --structure-limit 2 --multiword-limit 6
```

The streamed TSV has one `pool` metadata row, followed by `row` union candidates
and `token` exact-path evidence, ending with a blank line. Metadata records
completion/certified count, A* expansions, peak frontier, graph edges, stop reason,
suffix states and suffix transitions. Candidate rows retain native/k-best ranks,
per-stage membership, exclusion/replacement indices, lexical/context scores,
language, trace validity, exact score and original eligibility/score. Token rows
retain exact text, language, original UTF-8 source spans, paired word IDs/counts,
unigram/gram/context/spelling contributions and wildcard eligibility.
Report native, k-best (with completion status), union, post-structure, post-length,
post-quota and selected-pool recall, plus gained/lost IDs and replacement texts.
The app does not use this inspector, and no latency-safe deployment or neural
accuracy improvement follows from these offline stages.

## Statistical score and presentation

Ordinary base grams reward each word position using exactly one matching record:
the last-two-word trigram, otherwise the last-word bigram, otherwise zero.
With `p = P(word)`, `q = count(history, word) / sum_next count(history, next)`
and `c = count(history, word)`, the bit reward is
`clamp(log2(q/p), 0, cap) * c/(c+k)`; bigrams also multiply by `d`.
The defaults are `k=10`, `cap=5`, `d=0.7` under `[statistical_scoring]` in
`config/si.conf`. The cap applies before confidence and discount. A matched
trigram with zero reward still prevents bigram fallback. Higher stored orders
do not change the three-word ceiling, and short histories still discount
bigrams. User-boosted priors use the same reward formula in the personalized
lane; the separate user-model gram interpolation retains its existing policy.

If neither observed order matches, the base score uses a bounded backoff penalty.
Let `s = min(outgoing_count(last_word), incoming_count(next_exact_word_ID))`.
The penalty is `B * max(0, s-m)/(s+k_backoff)` bits, with defaults
`B=1`, `m=32`, `k_backoff=100`. This multiplies the unigram by
`alpha = 2^(-penalty)`. Sparse histories and successor tokenizations absent from
the corpus remain neutral. Missing higher orders never penalize a matching bigram.
Both the base and personalized lanes and preceding-field history mixtures use
the same base adjustment; user-model gram boosts remain separate. Prefixes use
only consumed spelling. A zero backoff cap restores the former missing-record
behavior. Observed rewards keep their existing policy, so this is not a fully
normalized backoff probability model.

The local `chiyoushijian` investigation found no exact `吃有时间` substring in
the three `si-corpus/*/text.txt` inputs selected by `si-corpus-ingest.sh`.
The separate `raw-text-v2/lccc/text.txt` snapshot contained three occurrences;
the current written-text segmenter attaches `吃` to a preceding word in all
three, then emits `有时间` as one token. The paired gram snapshot has 24,414
outgoing observations for `吃`, 1,062 incoming observations for `有时间`, and
no `吃 → 有时间` record. These local files are not a complete provenance log of
all historical snapshot imports, so counts do not establish linguistic impossibility.
The default penalty for that edge is about 0.886 bits. This evidence supports
a bounded adjustment rather than an unconditional penalty for every missing gram.

With the same local snapshots, correction both off and conservative, unavailable
preceding text and no personal state, `持有时间` keeps its -24.472344-bit score;
`吃有时间` changes from -23.787638 to -24.674041 and becomes second.
The 1,020-query authored recall suite changes from 830 to 839 full-pool hits,
739 to 756 Recall@9 hits, and 434 to 442 first-choice hits. Eleven previously
missing targets enter the pool and two leave it; 20 references become first
and 12 cease to be first. The changed beam order can lose valid constructed
paths. These regression measurements do not establish representative quality,
segmentation consistency, host compatibility or keystroke latency.

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
gram-rewarded conditional probabilities, then takes log2. Ingestion remains single-best.
Caller-owned Rust caches reuse immutable preparation for the same final fragment
and resource/configuration instance. They do not cache candidates or model scores.
See [field-context architecture](ARCHITECTURE.md#rust-conversion) for search bounds,
base/user histories, lifecycle and privacy.

## Exact terminal-completion pruning

- `1de758e` bounds a word's probability by the larger of its unigram prior
  and its largest observed continuation fraction across active histories.
  The base gram reward cannot exceed `log2(continuation/prior)`, so the
  resulting probability stays below the larger input; user boosts have the
  same upper bound. The bound includes the completion cost
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
These pruning optimizations do not change beam widths, candidate limits,
dictionary branches, score formulas or selection behavior.

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
