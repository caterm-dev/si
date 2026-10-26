# Candidate ranking

Chinese lookup, English lookup, Chinese sentences, English sentences and bilingual paths use the same `CandidateScoring` cost scale. Complete candidates and prefixes compete by their full-input effective score in `CandidateEngine`; no language category reserves a front position. The exact original input remains the final explicit candidate. These are comparable heuristic scores, not calibrated sentence probabilities or a production accuracy claim.

## Shared dictionary weights and word costs

`Data/DictionaryFormat.json` pins `si-relative-frequency-v1`: one point is one share of a fixed reference mass of 7,694,577,936, the initial Chinese text/reading weight sum. Chinese stored weights stay unchanged. Initial English probabilities, normalized over retained words and an unknown floor, were multiplied by that mass and rounded to integer weights. Both public overlays use these units. Ordinary dictionary edits do not rescale stored weights, and this ranking change does not edit dictionary data.

Every lexical token uses the same cost in bits:

```text
wordCost = (20 - ln(max(1, weight)) + (single Chinese character ? 2 : 0)) / ln(2)
baseScore = -sum(wordCost + spellingCost + languageCost) + contextBonus
```

The 20-nat per-word insertion cost and two-nat Chinese-character cost are retained SI heuristics. The former Chinese score's `20 × syllableCount` offset is removed, so coverage by more Chinese syllables no longer inflates a score relative to English or mixed paths. The English lookup and lexical decoder use the shared word cost instead of a separate vocabulary-normalized scoring objective. The older `LexicalLanguageModel` remains for historical probability-contract tests and is not used for runtime candidate costs.

## Spelling and language transitions

English `WordPrefixChannel` and Chinese `PinyinSpellingChannel` share a finite normalized spelling channel. The exact endpoint has weight 16; an observation missing `m > 0` letters has weight `2^-m`. Dividing by `16 + 1 - 2^-M` normalizes the channel, where `M = L - 1` for an English word's nonempty prefixes and `M = L` for a Chinese syllable, including its zero-letter observation. Cost is the negative base-two logarithm of this normalized weight. Completing the final missing letter therefore improves the spelling score by five bits; each earlier letter improves it by one bit. The sixteenfold exact-endpoint weight is an SI heuristic, not measured typing statistics or a guarantee that every exact match beats every completion.

Chinese applies this channel independently to each syllable, preserving spelling costs across word segmentations. Missing syllables use zero observed letters; initials observe only their typed letters. English uses the same word channel in direct lookup, preview and English/mixed sentence edges. Personal codes retain their shared word-prefix channel. Canonical umlaut aliases share spelling costs, while source offsets still consume the exact original spelling. Fixed correction aliases retain their existing lookup scope; this does not add a general typo model.

With empty learning and both languages enabled, `ma` leads with `吗` rather than five English completions; `may`, `man` and `make` remain selectable. Complete English words receive the same spelling advantage. A tradeoff is stronger preference for complete word sequences: on the known fixtures, `togethe` now leads with `to get he` instead of `together`, and `performa` leads with `perform a` instead of `performance`. The completion targets remain within five. Broader calibration remains open.

The first token pays a one-bit language prior. Later tokens pay `-log2(1-p)` when staying in one language or `-log2(p)` when switching, using the existing synthetic `RankingCalibration.switchProbability`. A Chinese token has the same word/spelling cost alone or before an English word. An English token has the same cost in direct lookup, an English sentence and a bilingual sentence; only its preceding language transition differs.

For `ling`, the full reading `零` competes against `li` + `ng` → `里NG`. The latter pays two word costs and a language switch. It stays available but has no reserved fourth position. English completions such as `lingo` also compete by score; this policy does not guarantee five Chinese homophones in the compact strip.

## Context, bounded search and personalization

The pinned Chinese word-bigram table contributes twice its positive increment during continuation search. Chinese word trigrams rescore terminal/prefix paths; the mixed decoder accumulates the same evidence within Chinese runs and uses it for presentation/terminal selection. English boundaries restart Chinese word context. A single surviving Chinese sentence receives the same trigram scoring as a sentence with competitors. Direct Chinese lexical choices include the corresponding beginning-of-sequence context. No English context corpus is invented and no surrounding host text is read.

Chinese continuation arithmetic remains in natural-log units and converts to bits at preference/presentation boundaries. The 32-path Chinese base beam, bounded personalized lane, seven-syllable/32-row spans, terminal alternatives and lexical-prefix pools remain. English/mixed search retains its twelve-path state beams, separate base/personalized selections and bounded terminal/prefix pools. Search can still omit desired candidates. Mixed initial-only Chinese edges, broad language-boundary detection and incomplete Chinese-tail prediction remain limited.

Whole-input and eligible previous-word preferences participate before presentation limits. Token and whole-input frequency share a 32-point cap through their maximum; previous-word preferences add at most 12 points. Prefix preferences use only consumed source spelling. Paths containing personal or verbatim nodes never train learning/context, and sentences are never decomposed into automatically retained token records.

Explicit personal phrases use a shared 10,000-weight insertion prior and their code's spelling cost, with a one-bit pin adjustment. Direct phrase scores no longer depend on dictionary size. An exact pinned phrase remains an explicit override; an unpinned phrase is available but does not reserve the first position. The 12-node personal fanout, 4,096-byte constructed-output bound, consent, retention and deletion rules remain unchanged.

## Accounting for the whole composition

`InputCandidate.rankingScore` retains the lexical score for the spelling actually consumed. `remainingInputScore` is transient request-local evidence, and `inputScore = rankingScore + remainingInputScore` is the comparison score before preferences. Complete choices keep their base score. Prefix word frequencies, committed text, language identity and exact consumed spelling remain unchanged; storage continues to retain the base score rather than the suffix projection.

A compatible complete hypothesis supplies a prefix's continuation score when both the exact source boundary and output UTF-8 bytes agree. The resulting prefix action scores one bit below that complete hypothesis before consumed-spelling preferences. Shared immutable traces record actual word boundaries. Exact full-reading Han rows with one character per syllable additionally supply validated interior alignments; initials, corrected/unmatched spelling and non-Han outputs do not receive guessed character boundaries. English spacing and mixed raw output retain separate byte offsets. This projection does not create automatic-confirmation evidence or force a display position.

Other prefixes reuse suffix paths from the same bounded search. Chinese BOS bigram/trigram increments are replaced with the actual prefix/suffix word context, and language transitions replace a second synthetic BOS prior. Missing boundaries can bridge to up to three retained suffix positions within twelve source characters, preserving two tail alternatives per bridge. Equal bridge spellings share a request-local query cache. Two sixteen-state lanes preserve contextual and context-free leading-word alternatives. Supplemental decoder queries use the existing engines with smaller budgets: the Chinese primary sentence cut, cached English completions and mixed lookup limited to 64 reading visits, eight readings per end and sixteen rows per reading. Full candidate generation retains its normal budgets and every enabled lane.

A long unsupported tail without a nearby retained path uses an explicit unknown-span cost instead of triggering another whole-input search for every prefix. Unknown spelling costs the existing weight-one word prior plus eight bits per unconverted UTF-8 byte. Literal fallback itself always preserves exact input and remains explicitly selectable; it is never used as a zero-cost explanation for ignored input.

The additional prefix confirmation costs one bit (`-log2(1/2)`), an explicit uniform binary action prior. It is a heuristic, not a measured user probability. Positive-cost sensitivity checks and fixed synthetic quality results are recorded in [verification](VERIFICATION.md); no phrase-specific multiplier or dictionary reweighting was introduced. Strong consumed-word preferences and genuinely better alternate paths can still make a prefix lead. The window has no two/five-whole quota or prefix insertion rule.

Lookahead never adds a preference for the uncommitted suffix or saves its words. Personal/verbatim paths keep their exclusions; context-free lookahead alternatives remain available. Source/word traces are private in-memory request data. Current-candidate validation ignores only this new projection metadata while retaining the prior identity, score, span and public-value checks. Revision/client checks and commit validation remain in place.

## Merge and presentation

`CandidateEngine` keeps the strongest language/text/source-span derivation after preferences, preserving single-lexical-unit evidence. Whole candidates and prefixes compete together by full-input effective score, without whole/prefix, consumed-span or lexical-type precedence, with exact pinned personal phrases as the explicit exception and canonical candidate identity as the deterministic tie-break. Identical text in different languages remains distinguishable. No provider leader is inserted ahead of higher-scoring candidates.

The input window uses a separate presentation policy with a 27-result ordinary budget. Every generated Chinese dictionary character is additionally retained, so complete character alternatives stay accessible on further pages. Complete-syllable characters also bypass the old preview and 24-word prefix limits; other search beams remain bounded. Sentence-led compositions show up to four constructed hypotheses, then only single-character/word choices. Required first choices for matching language/mixed identities count toward those four slots. Word-led queries keep engine order among retained choices. Extra sentences and multiword fragments remain in the engine, without filling later window pages. A word is identified by single-lexical-unit metadata, with explicit personal phrases and punctuation choices also eligible. The first result per language/mixed identity, first complete word per single-language identity, first history suggestion and exact literal are protected. App History keeps its placement after the first two whole choices; the literal stays last. Scores and provisional/full engine merging are unchanged.

Automatic confirmation keeps its opt-in boundaries and English/code safeguards. Mixed candidates supply no automatic-confirmation evidence. Native event routing, host compatibility and VoiceOver require separate manual verification.

## Validation

`CandidateScoringTests` covers `ling` in provisional/full results, monotonic complete-candidate scores, cross-decoder word/context consistency, spelling costs, language filtering, deterministic identity, literal fallback and personal pins. `CompositionCoverageTests` checks compatible-path projection, exact byte/source alignment, Han/umlaut separators, associative bridge scoring, explicit unknown tails, unchanged word frequencies and prefix-only learning. `CandidateSelectionTests` checks that the shortlist keeps `零` ahead of `里NG`, retains all matching identities and can commit the selected character through expanded numbering. Existing mixed, English, learning, cancellation and source-boundary regressions remain active. See [the current verification record](VERIFICATION.md) for actual outcomes and existing failures.

```sh
./scripts/test.sh
./scripts/test.sh --filter CandidateScoringTests
./scripts/build.sh
```

The retained dictionary-generation checks and provenance are documented in [Chinese maintenance](CHINESE_VOCABULARY.md) and [English maintenance](ENGLISH_VOCABULARY.md). Formula consistency does not establish that the imported corpora, heuristic costs or bounded search are linguistically optimal. Broader quality calibration remains open.
