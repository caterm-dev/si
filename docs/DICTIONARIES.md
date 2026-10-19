# Vocabularies and decoding

Chinese characters/phrases remain original, manually specified SI data in `OriginalPinyinLexicon.swift` under GPLv3. English is generated from a pinned ESDB/SCOWL selection, the original SI list, and SI-maintained terminology. The application does not download data or copy installed system dictionaries.

The Chinese list contains 979 lexical alternatives (290 multi-character alternatives). The initial maintained English import contains 61,216 case-insensitively unique word forms. These counts describe data, not coverage or accuracy. Current English counts, source versions, checksums, filters and completion priorities are recorded by the [maintenance pipeline](ENGLISH_VOCABULARY.md) and its [generated summary](../Data/English/generated/summary.json).

## English

Source snapshots, licenses and local overrides live in `Data/English/`. The generated `EnglishLexiconData.swift` is compiled by both targets. `EnglishLexicon` builds immutable lowercase lookup keys once when the default candidate engine is constructed; exact and prefix lookup use binary search over sorted keys. No per-word prefix arrays or per-key full-list scan is required. Direct English matches remain unbounded; constructed mixed paths retain the existing bounded search limits.

English exact matches score 110. Original SI and terminology completions score 85; imported completions score 75. These are editorial preferences, not measured frequencies, and apply to both direct lookup and mixed continuation. Importing a new word can change segmentation and which constructed candidates reach the bounded shortlist. Complete original input always remains independently available. Spelling correction and independent production-quality evaluation remain future work.

## Chinese

Each entry specifies syllables, output text, and an initial ranking score. The compact source uses `reading|alternative alternative`; alternatives have decreasing scores starting at 100. These are editorial preferences, not measured word frequencies. `v` denotes ü; the decoder also normalizes ü and `u:` spellings when called directly.

The decoder supports:

- Exact words and phrases, case-insensitive phonetic lookup, and exact original-text preservation in the engine.
- Explicit apostrophe boundaries: `xian` may match both `先` and `西安`, while `xi'an` excludes the single-syllable reading.
- Prefix completion of a stored reading, including an incomplete final syllable.
- All-initial abbreviations of stored phrases, such as `srf` for `输入法`, and mixed full/initial readings such as `nhao` for `你好`.
- Word-lattice composition of complete readings, including combinations not stored as full phrases.
- Interleaved English words and Chinese readings, with known-word completion at the final position when both languages are enabled.
- Bounded preservation of unrecognized spans, including original casing, when no exact non-abbreviated complete path exists. These paths are labelled Chinese + As Typed and cannot train learning or previous-word context.
- Prefix confirmation using exact source-character boundaries, leaving the remainder marked and editable. Whole candidates precede prefixes; longer prefixes precede shorter ones.

Direct Chinese entries score around 100, English exact matches 110, English completions 75 or 85, Chinese completions around 84, and stored-phrase abbreviations around 78. Constructed paths use fractional ranking below direct exact matches, with costs for segmentation, completion, language transitions, and verbatim spans. Fractional ranking preserves small differences on long compositions. These are editorial scores for the optional learning bonus, not a trained probabilistic model.

Manually saved [personal phrases](USER_PHRASES.md) join the merge at score 115 for full codes, 180 for preferred full codes, and 80 for prefixes. Saved codes also form intermediate lattice nodes. Paths containing any personal node remain excluded from automatic learning/context. Deduplication keeps the strongest derivation rather than whichever provider happened to run first. Mixed candidates carry an explicit mixed identity; Latin letters in a manually declared Chinese phrase do not change its saved language.

## Search limits and remaining work

Continuation search retains 12 base-cost paths and, where token preferences apply, up to 12 additional personalized paths per language-combination, last-language, and verbatim-state combination at each position. Terminal selection uses actual candidate scores, retaining 12 base-ranked and up to 12 personalized paths per state. Prefix presentation independently keeps two distinct results per language combination and consumed span, before continuation pruning. Personal nodes use at most 12 alternatives per language/code; constructed outputs are limited to 4,096 UTF-8 bytes without truncation. All direct lexical/personal matches remain independent of these bounds; the merged engine has no global candidate cap. Results are deduplicated by language, text, and consumed-prefix identity with deterministic ordering. The decoder accepts at most 64 normalized letters and 256 source bytes; longer or invalid compositions still have exact literal fallback. Mixed full/initial variants are enumerated for phrases of up to six syllables; longer entries support only full spelling and all initials.

Single-language frequency preferences influence matching tokens before continuation pruning. Whole-input preferences and separate previous-word pairs also apply before terminal/prefix presentation limits, so a candidate already reaching that position can benefit before being discarded. Token and whole-input frequency share a 32-point cap using their maximum; token contributions are weighted by consumed normalized-letter length. Eligible previous-word pairs add at most 12 points. They do not change internal token transition costs. No confirmed sentence is automatically decomposed into new saved token records. Personal/verbatim paths receive no learning bonus.

Unknown-span boundaries use lexical heuristics, not a general language detector. Tone-number input and fuzzy Pinyin remain unsupported. Bounded beams can still omit intended constructed alternatives. The controller accepts ASCII letters and apostrophes; use `v` for ü when typing through SI. Number keys select candidates rather than tones.

Ten held-out synthetic everyday sentences have top-choice regression coverage, including `mingtianwomenqubeijing` → `明天我们去北京`. The test verifies these sentences are not stored as whole entries. This small authored suite is a regression check, not independent accuracy evaluation.

Limited character and phrase coverage can cause an intended Chinese reading to be absent or a less natural constructed path to rank ahead. New original entries should have explicit readings, focused regression tests, and provenance if the source policy changes. Do not describe an expanded list as a production decoding engine without broader coverage and input-quality evaluation.
