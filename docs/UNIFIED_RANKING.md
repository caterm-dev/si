# Candidate ranking

Chinese lookup, English lookup, Chinese sentences, English sentences and bilingual paths use the same `CandidateScoring` cost scale. Production orders candidates by coverage group and compares their scores within each group. No language category reserves a front position. The exact original input remains the final explicit candidate. These are comparable heuristic scores, not calibrated sentence probabilities or a production accuracy claim.

## Shared dictionary weights and word costs

`Data/DictionaryFormat.json` pins `si-wanxiang-weight-v1`, with `reference_mass=1`: one base point is one unchanged integer weight from the pinned `rime-wanxiang-data` source. Chinese (`zi`/`jichu`/`duoyin`) and English (`en`) no longer use the previous Chinese-reference mass or wordfreq normalization. The upstream values are transformed ranking weights, not normalized probabilities or raw counts. Local category CSVs use weight 10, also the default for new local additions; base weights and English casing take precedence over category overlaps, followed by imported category weights over legacy copies; duplicates within each tier merge by maximum weight. The unit/version change makes old packaged resources fail closed rather than silently mixing old and new bases. Both unknown weights are one. Explicit SI weight corrections, including `上次` from 21,766 to 40,000, are recorded in [Chinese maintenance](../Data/Vocabulary/chinese/README.md#si-editorial-weight-adjustments); these are editorial values rather than new occurrence measurements.

The conversion keeps supplied weights, collapses tone-only Chinese identities by maximum weight and resolves English case-only variants by highest weight with pinned-source-order ties. Missing weights are stored as zero and retain the existing scoring floor of one. See [the import report and exceptions](../Data/Vocabulary/Wanxiang/README.md). The import initially retained the former 20-nat word and two-nat character costs. Subsequent synthetic experiments reduced them to 19.5 and 1.75 nats and tested 10/1. The user then requested restoring 20/2 while retaining the 1.05 frequency coefficient. Historical tradeoffs are recorded in [testing](TESTING.md#reduced-word-and-character-penalties). Vocabulary/weight changes can alter homophone, segmentation and mixed-language results; equal source units do not establish cross-language statistical calibration or Wanxiang/Rime runtime parity.

Every lexical token uses the same cost in bits:

```text
extraCost = English dictionary token ? 3 : (single Chinese character ? 2 : 0)
wordCost = (20 - 1.05 * ln(max(1, weight)) + extraCost) / ln(2)
baseScore = -sum(wordCost + spellingCost + languageCost)
```

The 20-nat per-word insertion cost, two-nat Chinese-character cost, three-nat English-token cost and 1.05 log-frequency coefficient are SI heuristics. The English addition applies once per dictionary token, including single-letter words, direct and cached-preview lookup, completions, and each English sentence/mixed-path edge or consumed prefix. It is three nats (about 4.328 score bits), one nat above the Chinese-character addition. Explicit personal-code priors and unrecognized verbatim costs are unchanged. With empty personal state, `me` now ranks `么` above English `me`, and `麼` above the completion `men`; all remain selectable. The coefficient amplifies a tenfold dictionary-weight advantage from about 3.322 to 3.488 bits while leaving insertion, spelling, and language costs unchanged. It applies inside the shared `wordCost` to direct, constructed, prefix and personal paths across languages; learned-preference bonuses keep their existing units and limits. They reduce the advantage of a smaller number of low-frequency words over frequent standalone characters: `heshangcibi` now has `和上次比` as its leading complete conversion instead of `和尚刺鼻`, without phrase-specific rules. Ordinal homophones remain ambiguous; the historical ordering measurements below used earlier insertion costs. These costs do not model semantic compatibility. The former Chinese-only `20 × syllableCount` offset remains removed. The shared presentation coverage reward described below counts consumed source letters/digits equally across languages, independently of syllable count. The English lookup and lexical decoder use the shared word cost instead of a separate vocabulary-normalized scoring objective. The older `LexicalLanguageModel` remains for historical probability-contract tests and is not used for runtime candidate costs.

## Runtime model status

No language model is loaded or queried during candidate generation. Ranking uses
dictionary, spelling and language-transition costs plus eligible personalization
and the shared consumed-input coverage reward.
The large-model direction remains planned; `llm/` is an independent offline experiment.

## Spelling and language transitions

English `WordPrefixChannel` and Chinese `PinyinSpellingChannel` share a finite normalized spelling channel. The exact endpoint has weight 16; an observation missing `m > 0` letters has weight `2^-m`. Dividing by `16 + 1 - 2^-M` normalizes the channel, where `M = L - 1` for an English word's nonempty prefixes and `M = L` for a Chinese syllable, including its zero-letter observation. Cost is the negative base-two logarithm of this normalized weight. Completing the final missing letter therefore improves the spelling score by five bits; each earlier letter improves it by one bit. The sixteenfold exact-endpoint weight is an SI heuristic, not measured typing statistics or a guarantee that every exact match beats every completion.

Chinese applies this channel independently to each syllable, preserving spelling costs across word segmentations. Missing syllables use zero observed letters; initials observe only their typed letters. English uses the same word channel in direct lookup, preview and English/mixed sentence edges. Personal codes retain their shared word-prefix channel. Canonical umlaut aliases share spelling costs, while source offsets still consume the exact original spelling. Fixed correction aliases retain their existing lookup scope; this does not add a general typo model.

With empty learning and both languages enabled, `ma` leads with `吗` rather than five English completions; `may`, `man` and `make` remain selectable. Complete English words receive the same spelling advantage. A tradeoff is stronger preference for complete word sequences: among complete candidates on the known fixtures, `togethe` favors `to get he` instead of `together`, and `performa` favors `perform a` instead of `performance`. The completion targets remain within five complete candidates; prefixes can rank ahead of them. Broader calibration remains open.

The first token pays a one-bit language prior. Later tokens pay `-log2(1-p)` when staying in one language or `-log2(p)` when switching, using the existing synthetic `RankingCalibration.switchProbability`. A Chinese token has the same word/spelling cost alone or before an English word. An English token has the same cost in direct lookup, an English sentence and a bilingual sentence; only its preceding language transition differs.

For `ling`, the full reading `零` competes against `li` + `ng` → `里 NG`. The latter pays two word costs and a language switch. It stays available but has no reserved fourth position. English completions such as `lingo` also compete by score; this policy does not guarantee five Chinese homophones in the compact strip.

## Context, bounded search and personalization

Chinese sentence construction retains its bounded six-terminal selection, dictionary
weights and syllable channel. No corpus context is applied. Historical MSNG artifacts
remain under `Data/Chinese/MSIME/artifacts/` for provenance/compatibility checks and
are excluded from App resources.

Chinese continuation arithmetic remains in natural-log units and converts to bits at preference/presentation boundaries. The 32-path Chinese base beam, bounded personalized lane, seven-syllable/32-row spans, terminal alternatives and lexical-prefix pools remain. English/mixed search retains its twelve-path state beams, separate base/personalized selections and bounded terminal/prefix pools. Search can still omit desired candidates. Mixed initial-only Chinese edges, broad language-boundary detection and incomplete Chinese-tail prediction remain limited.

App vocabulary separates usage from preference: accepting the displayed first choice only counts usage, while every three explicit nonfirst choices add one ranking point. This app policy stores strength in the shared logarithmic model's units, preserves its 32-point cap and 14-day strength half-life, and does not change core library fixtures. Counts and strengths persist independently in schema 3; schema-1/2 migration preserves usage but resets old mixed ranking evidence.

Whole-input and eligible previous-word preferences participate before presentation limits. Token and whole-input frequency share a 32-point cap through their maximum; previous-word preferences add at most 12 points. Prefix preferences use only consumed source spelling and retain their full capped bonus, without scaling by total input length. The same rule applies before prefix presentation limits, during provisional/full merging and to session presentation scores. Paths containing personal or verbatim nodes never train learning/context, and sentences are never decomposed into automatically retained token records.

Explicit personal phrases use a shared 10,000-weight insertion prior and their code's spelling cost, with a one-bit pin adjustment. Direct phrase scores no longer depend on dictionary size. An exact pinned phrase remains an explicit override; an unpinned phrase is available but does not reserve the first position. The 12-node personal fanout, 4,096-byte constructed-output bound, consent, retention and deletion rules remain unchanged.

## Prefixes use only consumed spelling

`InputCandidate.rankingScore` is the lexical score for the spelling actually consumed, and `inputScore` equals that score. A prefix's frequency, spelling cost and eligible preferences do not depend on the pending suffix's length, languages or possible conversions. There is no suffix projection, suffix provider query, unknown-byte penalty or extra confirmation cost. Adding or removing a weak whole candidate cannot change a prefix's score.

For example, `词` in `cichuxiande` competes with its own `ci` lexical/preferences score plus ten coverage points; a mixed `词出现 De` hypothesis cannot improve or weaken it. Prefix identity and commits still include the exact consumed source boundary, including apostrophes and umlaut aliases. Confirmation leaves the exact remaining spelling editable and does not append an English space. Only the consumed spelling is eligible for learning.

Complete candidates continue to score all the lexical units and spelling they consume. Presentation adds a soft coverage reward:

```text
presentationScore = baseScore + eligiblePreferenceBonus + 5 * matchedSourceLettersAndDigits
```

Only consumed spelling counts. Apostrophes, punctuation, and the colon in u: earn nothing; ü/v/u: aliases count equally. A completion earns no credit for predicted letters beyond the input. Paths containing unrecognized verbatim spans receive no coverage reward. Splitting the same source into more words or emitting more output does not increase coverage points. Production uses the reward within coverage groups. Base lexical scores, learning caps, sentence search bounds, stale-result checks and exact literal fallback retain their existing contracts. Historical suffix/confirmation calibration results no longer describe the current prefix policy.

The five-point coefficient was selected with authored development/regression fixtures, not independent typing data. [Rime compares consumed ranges before quality](https://github.com/rime/librime/blob/master/src/rime/candidate.cc#L30); [libime protects n-best sentences and adjusts partial candidates by remaining graph distance](https://github.com/fcitx/libime/blob/master/src/libime/pinyin/pinyincontext.cpp#L664). SI applies a matched-source reward and groups by consumed source span without estimating future words.

## Merge and presentation

`CandidateEngine` keeps the strongest language/text/source-span derivation after preferences, preserving single-lexical-unit evidence. Production keeps pins and remembered choices first, then groups whole candidates ahead of prefixes and longer consumed prefix spans ahead of shorter ones. Within a group, the coverage-adjusted score includes the local Chinese KenLM contribution when available and the 28-bit English insertion cost. Canonical identity breaks ties. Identical text in different languages remains distinguishable. No provider leader is inserted ahead of higher-scoring candidates.

The input window uses a separate presentation policy with a 27-result ordinary budget, including the exact literal. Every generated Chinese dictionary character is additionally retained, so character alternatives stay accessible on further pages. Complete-syllable characters also bypass the old preview and 24-word prefix limits; other search beams remain bounded. The first four ranked choices may include constructed sentences, mixed paths and multiword fragments. Later ordinary slots contain single lexical units, explicit personal phrases or punctuation choices. Sentence alternatives below fourth place remain in the engine rather than filling later window pages. A word already in the leading four is not displaced by a lower-ranked sentence, and language leaders have no reservation. The exact literal stays last. Font filtering precedes budget allocation in the window; the offline shortlist does not model machine-specific font availability.

Automatic confirmation keeps its opt-in boundaries and English/code safeguards. A plausible competitor under either the legacy or adjusted score can block a prefix. Mixed candidates supply no automatic-confirmation evidence. Native event routing, host compatibility and VoiceOver require separate manual verification.

## Validation

`CandidateScoringTests` covers `ling` in provisional/full results, monotonic complete-candidate scores, cross-decoder word-cost consistency, spelling costs, language filtering, deterministic identity, literal fallback and personal pins. `CompositionCoverageTests` checks prefix-score invariance under changed whole paths and unknown/long tails, no suffix queries, exact byte/source alignment, umlaut aliases/separators, unchanged word frequencies and prefix-only learning. `InputCoverageRankingTests` checks whole-input Chinese/English defaults, selectable mixed sentences, same-span split/completion neutrality, punctuation and verbatim exclusions. The presentation suite renders and commits continuous sentences from the first cell in both layouts and appearances. `CandidateSelectionTests` checks that the shortlist keeps `零` ahead of `里 NG`, retains all matching identities and can commit the selected character through expanded numbering. Existing mixed, English, learning, cancellation and source-boundary regressions remain active. See [the current verification record](VERIFICATION.md) for actual outcomes and existing failures.

```sh
./scripts/test.sh
./scripts/test.sh --filter CandidateScoringTests
./scripts/build.sh
```

The retained dictionary-generation checks and provenance are documented in [Chinese maintenance](CHINESE_VOCABULARY.md) and [English maintenance](ENGLISH_VOCABULARY.md). Formula consistency does not establish that the imported corpora, heuristic costs or bounded search are linguistically optimal. Broader quality calibration remains open.
