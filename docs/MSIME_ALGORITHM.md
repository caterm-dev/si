# MSIME Chinese algorithm study

This study reads the upstream implementation, not just its README. Engine revision: [`0fce42f0dd22fe6930b5a1942498280df8073396`](https://github.com/metasequoiaime/msime/tree/0fce42f0dd22fe6930b5a1942498280df8073396). Dictionary revision: [`b32ac7227135255a3351f02ec5bdfc983741e81a`](https://github.com/metasequoiaime/msime-dictionary/tree/b32ac7227135255a3351f02ec5bdfc983741e81a). These describe a fixed snapshot, not every version or the configuration used in a particular installation.

The user confirmed that the reference installation uses default settings without optional AI reranking or autocorrection. That default pipeline is the current SI alignment target.

At the user's subsequent request to follow the latest open-source code, the repository's default develop branch was read at d05c33e54ff72673fd583f5ac0f79c4fe5688560. Its complete pinyin, quanpin, dictionary and lattice subtrees, type/format definitions, runtime session files and reading-correction file have the same Git objects as the retained source snapshot; only the session tests differ in that subtree. The dictionary main branch is still the retained b32ac722 revision. [upstream-review.json](../Data/Chinese/MSIME/upstream-review.json) records that source-only comparison and its timestamp. It does not establish correctness of the Swift port.

## Main conclusion

The default full-Pinyin pipeline combines dictionary lookup, bounded segmentation, word-lattice search, word bigram/trigram context and explicit candidate-placement rules. Dictionary frequency alone does not explain its sentence behavior. Optional neural rerankers and general typo correction are separate capabilities, disabled by default in the inspected session options.

```text
typed Pinyin
  → minimum-syllable cuts / fixed spelling aliases
  → exact → trailing-prefix → mixed-initial → pure-initial dictionary cascade
  → lexical candidates and longer-word completions
  → primary complete-reading word lattice
  → beam search with word bigrams
  → six distinct sentences, then trigram rescoring
  → place the winning sentence after leading full-key dictionary answers
  → merge alternative full-key readings and shorter prefix groups
```

Sources: [segmentation](https://github.com/metasequoiaime/msime/blob/0fce42f0dd22fe6930b5a1942498280df8073396/crates/engine/src/pinyin/segment.rs), [lookup cascade](https://github.com/metasequoiaime/msime/blob/0fce42f0dd22fe6930b5a1942498280df8073396/crates/engine/src/dictionary/pinyin.rs), [query orchestration](https://github.com/metasequoiaime/msime/blob/0fce42f0dd22fe6930b5a1942498280df8073396/crates/engine/src/quanpin/dictionary.rs), [sentence placement](https://github.com/metasequoiaime/msime/blob/0fce42f0dd22fe6930b5a1942498280df8073396/crates/engine/src/lattice/merge.rs).

## Segmentation and spelling

The inventory contains 421 complete syllables and their prefixes. Dynamic programming minimizes the number of segments; equal counts prefer the shorter first segment, handing a consonant to the next syllable. Explicit apostrophes constrain cuts. The full-Pinyin scheme also uses a fixed spelling-alias table independently of the general autocorrect switch. This channel retains at most 32 minimum-segment readings with deterministic alias priorities. It is narrower than an unrestricted edit-distance search.

Complete alternative cuts are bounded and considered for input without explicit apostrophes whose primary cut contains at most four intact syllables. Their exact dictionary keys are grouped in table-name order, with at most 128 rows queried per table. The concatenated pages are stable-sorted by weight, without a global 128-row truncation or early word deduplication, then merged with primary full-key rows and deduplicated. In the default configuration, only the leading fixed-alias reading is primary; other alias readings join the competing alternatives only when general autocorrection is enabled. A best alternative at least one hundredth of the primary frequency gets a protected second seat if it would otherwise fall outside the first six. This is an explicit display rule rather than a sentence probability. See [alternative-cut merging](https://github.com/metasequoiaime/msime/blob/0fce42f0dd22fe6930b5a1942498280df8073396/crates/engine/src/quanpin/series.rs) and [batch lookup](https://github.com/metasequoiaime/msime/blob/0fce42f0dd22fe6930b5a1942498280df8073396/crates/engine/src/dictionary/pinyin.rs).

## Dictionary retrieval and candidate policy

SQLite tables are partitioned by syllable count (1–7, then an overflow bucket) and first Latin letter. Each row retains full reading, initials, output and integer weight. The query cascade first tries exact complete readings, then a trailing-key range, then filtered mixed initials, then pure initials. Single-letter lookup initially takes 24 rows. Automatic zh/ch/sh tokens can additionally be split into separate initials without changing explicit apostrophe boundaries. A small sparse-result fallback table handles dia, biang, gei and yo.

Longer-word completion queries up to three additional syllable buckets, treating overflow as one table and retaining three distinct outputs. The strongest exact same-length reading protects first place. If exact homophones do not fill the configured first page, completions compete with the remaining rows by frequency. If exact rows fill that page, completions are appended later. The generated sentence is inserted after the leading full-key dictionary run. A frequent completion therefore cannot simply take the first seat from the exact word.

These rules explain why a single shared score sort is insufficient, even after importing the same dictionary.

## Sentence search and scoring

The primary complete reading defines syllable-position columns. Dictionary words become edges covering at most seven syllables, with up to 32 lexical rows per span. Search retains a beam of 32 hypotheses per column. With source weight f and edge length n, the static natural-log score is:

```text
n = 1: ln(max(1, f)) − ln(1,000,000)
n > 1: ln(max(1, f)) + 20 × (n − 1)
```

SI intentionally diverges from this upstream formula after the October 22 frequency review: its single-character deduction is two nats, while the 20-nat word insertion prior and shared log-frequency coefficient remain. The smaller cost fixes the reported `nawomenzaichaxun` cross-boundary segmentation; completely removing it caused excessive character splitting. See [SI's current scoring and limits](UNIFIED_RANKING.md). The formula above continues to document upstream.

This is a heuristic length/word objective, not a normalized unigram probability. In particular, treating the integer weight as a universal final ranking score changes the algorithm.

Word bigram increments participate during search as `2 × max(0, increment)`. The table represents conditional log-ratio evidence over the unigram. Search first selects six distinct terminal sentences; word trigram increments then rescore those survivors with weight 1. The low-level options emit one constructed sentence unless sentence alternatives are requested. The actual [host enables alternatives unconditionally](https://github.com/metasequoiaime/msime/blob/0fce42f0dd22fe6930b5a1942498280df8073396/crates/host-api/src/lib.rs#L704-L708). Its [runner-up policy](https://github.com/metasequoiaime/msime/blob/0fce42f0dd22fe6930b5a1942498280df8073396/crates/engine/src/ordering.rs#L408-L427) groups three lattice readings for outputs of at least three characters, keeps one for shorter readings, and moves the remainder to the end rather than deleting them. Describing the low-level default as the product's displayed candidate policy was incorrect. Trigrams do not rescore every possible path. See [lattice options, graph and decoding](https://github.com/metasequoiaime/msime/blob/0fce42f0dd22fe6930b5a1942498280df8073396/crates/engine/src/lattice/decode.rs).

Equal-score ordering is part of this search. MSIME explicitly reproduces libc++ heap selection and introsort because stable or differently unstable sorts retain different zero-weight homophones and tied sentences. SI now has a Swift adaptation of those operations in `ChinesePathOrdering.swift`, with bounded streaming collectors in each lane. This is written source alignment, not runtime evidence of equality. See [the upstream sort implementation and rationale](https://github.com/metasequoiaime/msime/blob/0fce42f0dd22fe6930b5a1942498280df8073396/crates/engine/src/lattice/cxx_sort.rs).

The pinned word-context artifacts derive from a Chinese Wikipedia 2026-09-01 dump subset, segmented with the dictionary. Their builder uses count filtering, shrinkage and bounded increments. Missing entries contribute zero. The published MSNG v1 files store sorted FNV-1a word-sequence keys and float32 increments. These tables contain actual cross-word corpus evidence, unlike SI's previous dictionary-internal adjacent-character backoff. Corpus/artifact hashes and attribution are retained in [resources.lock.json](../Data/Chinese/MSIME/resources.lock.json). Format: [ngram.rs](https://github.com/metasequoiaime/msime/blob/0fce42f0dd22fe6930b5a1942498280df8073396/crates/engine/src/lattice/ngram.rs).

## What the reported examples establish

The pinned single-character source contains:

| Text | Reading | Source weight |
| --- | --- | ---: |
| 呢 | ne | 7,763,286 |
| 内 | nei | 1,362,462 |
| 原 | yuan | 2,656,054 |
| 远 | yuan | 34,600 |

These are explicitly read source rows, not model-generated estimates. The duplicate text/reading merge selects the larger source weight. Source: [single-chars.txt](https://github.com/metasequoiaime/msime-dictionary/blob/b32ac7227135255a3351f02ec5bdfc983741e81a/sources/pinyin/single-chars.txt). The [main lexical source](https://github.com/metasequoiaime/msime-dictionary/blob/b32ac7227135255a3351f02ec5bdfc983741e81a/sources/pinyin/rime-ice.txt) also contains 距离 / ju'li / 927,480 and 特别 / te'bie / 1,543,107.

For ne, 呢 has an exact reading while 内 is a completion of nei. Exact/completion policy matters in addition to the larger weight of 呢. Chinese and English source frequencies must not be treated as interchangeable counts when merging enabled providers.

For julitebieyuan, the source actually favors 原 over 远 by about 76.8 times in isolation. A natural sentence therefore cannot be explained by asserting that 远 must have the higher character frequency. Word segmentation, longer lexical entries and contextual transitions must be inspected together. This source inspection does not prove which contribution caused the observed MSIME first choice; a trace from the same resources and isolated configuration would be needed. The October 22 validation instead finds 距离特别圆 with the pinned resources: `距离` + `特别圆` wins in both Swift and an independent arithmetic calculation. The latter lexical entry has weight 3,984 and receives the three-syllable phrase bonus. This is not a full MSIME runtime comparison, and the requested 距离特别远 result remains unmet. See [validation evidence](VERIFICATION.md).

## Data and licensing

The Pinyin data largely derives from Rime Ice, with shared readings reweighted from rime-wanxiang v18.0.16, plus reading corrections and additions. The dictionary repository explicitly has per-source terms, not one blanket data license. The selected import excludes its separately marked unlicensed custom dictionary sources. Preserve the [upstream notice](../Data/Chinese/MSIME/NOTICE.md), revision locks and source-specific attribution when maintaining SI's derivative dictionary.

The engine adaptation is GPL-3.0-only. SI's runtime implementation is Swift; reading Rust source for the port does not introduce a Rust dependency. SI's own public lexical additions/exclusions belong in [si-entries.json](../Data/Chinese/MSIME/si-entries.json), separate from private user phrases and learned preferences.

## SI migration boundary

The current code connects Swift segmentation, lookup, candidate placement, word-lattice search and pinned bigram/trigram resources. SI retains its existing learning consent, storage, deletion, source-boundary editing and client isolation. Its bounded personalized lane, prefix presentation, and optional automatic-confirmation evidence are deliberate SI adaptations rather than claims of byte-for-byte MSIME behavior.

General optional typo paths and optional neural inference are not included in the confirmed default baseline. Existing English vocabulary and functionality remain separate; mixed lexical paths are deferred. The user authorized validation on October 22. Debug/Release compilation, resource reproducibility, model checksums and focused arithmetic/sort tests pass; complete regressions and Chinese quality still fail. No installation or live host typing check was performed. The written implementation does not establish equal conversion quality. See [the remaining work](IMPLEMENTATION_PLAN.md).
