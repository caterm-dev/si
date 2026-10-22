# Vocabularies and decoding

SI maintains its Chinese dictionary solely from MSIME-derived data. English retains its existing separate vocabulary and frequency sources by explicit user choice. Pinned compressed source text, reading corrections and an SI-owned public overlay generate one SQLite database containing text, explicit readings, integer weights and lookup indexes. Separately pinned MSIME word-context tables supply bigram/trigram increments. The application neither downloads dictionaries nor copies installed system data.

The former direct Rime Chinese selection and original SI tables have been removed with their dedicated Chinese maintenance adapter. SCOWL/CSpell/Rime English imports and wordfreq bins are retained. MSIME's underlying data still retains its required upstream provenance and licenses. See [Chinese maintenance](CHINESE_VOCABULARY.md).

## English and private data

English retains 63,602 word forms from its pinned SCOWL/CSpell/Rime selections and SI additions. `EnglishLexiconData.swift` and `EnglishFrequencyData.swift` still feed the shared immutable trie and word-scoring interface. Case-preserving direct lookup, completion and English-only composition remain available. Maintenance uses `scripts/vocabulary.py` and `scripts/ranking.py`; see [English maintenance](ENGLISH_VOCABULARY.md) for pins, notices and filtering.

Private personal phrases and aggregate learning archives are preserved with their existing consent, retention and deletion controls. Dictionary tools never inspect them. Exact original input remains independently available for all enabled-language configurations. English/code safeguards retain their existing lexical data.

## Chinese

The default Chinese decoder is a native Swift adaptation of MSIME, using an SI-maintained read-only SQLite dictionary and pinned word bigram/trigram tables. Debug and Release compilation and resource reproducibility checks pass. Full regression and Chinese quality checks still expose failures, and live host behavior remains unverified; see [verification](VERIFICATION.md). Earlier engine measurements do not describe it.

The retained sources generate 953,710 unique text/reading entries. MSIME's Rime Ice / rime-wanxiang weights are preserved rather than normalized into the former bilingual character-boundary model. SI uses a smaller two-nat single-character insertion cost instead of upstream's `ln(1e6)`, so frequent natural tokens can compete with low-frequency multi-character fragments. Dictionary entries and their stored weights are unchanged; see [the current scoring objective](UNIFIED_RANKING.md). The source revisions, reading corrections, SI-owned additions/exclusions overlay, licenses and reproducible maintenance commands are in [the dictionary directory](../Data/Chinese/MSIME/README.md). No system dictionary, Rust runtime or runtime download is involved.

The written lookup pipeline includes exact readings, trailing-prefix completion, full/initial combinations, pure initials, longer-word completion, bounded alternative complete cuts, fixed spelling aliases, retroflex-initial splits and sparse-result fallback. Apostrophes constrain source boundaries. Canonical umlaut aliases do not alter committed text or source consumption.

Word-lattice construction queries up to seven syllables and 32 lexical rows per span. A 32-path continuation beam uses lexical scores and positive word-bigram increments; six distinct terminal sentences are selected before trigram rescoring. Ordinarily the strongest constructed sentence is emitted. Direct lexical and saved personal matches remain independent of constructed-path limits. Explicit personal nodes retain the existing 12-alternative fanout and 4,096-byte constructed-output bound.

SI additionally retains its bounded personalized search lane, whole-input/previous-word preferences before presentation limits, and consumed-spelling prefix ranking. Token and whole-input frequency share a 32-point cap through their maximum; previous-word preferences add at most 12 points. Paths containing personal phrases cannot train learning or context. No sentence is automatically decomposed into retained token records.

Dictionary placement and sentence scoring are separate policies. The strongest exact reading protects the first seat; longer completions may compete for later seats when exact homophones do not fill the first compact page. Constructed sentences follow the leading exact run. Alternative full-key cuts can compete by frequency. These policies survive the engine merge rather than comparing Chinese and English corpus weights.

English lookup and English-only composition remain available in a separate lane. Chinese/English mixed lexical paths and unknown-span Chinese constructions are deferred until the Chinese baseline is established. An exact original-input candidate remains available for every nonempty composition, including invalid/unsupported input or disabled languages. The engine retains full results; the input window shortlists at most 27 while preserving language identities and exact input.

## Limits and unfinished work

The decoder accepts at most 64 normalized letters and 256 source bytes; unsupported input still has literal fallback. The controller accepts letters and apostrophes; use v for ü in native typing. Digits select candidates rather than tones. Explicit personal codes keep their existing validation and storage rules.

Fixed spelling aliases are narrower than general typo correction or configurable fuzzy Pinyin. General optional typo-path parity and optional neural models are not implemented. MSIME's neural rerankers are disabled by default; their absence must not be presented as complete feature parity. Bounded search can omit intended sentences, and imported vocabulary breadth does not establish conversion quality.

See [the pinned algorithm study](MSIME_ALGORITHM.md), [current ranking](UNIFIED_RANKING.md), [remaining implementation work](IMPLEMENTATION_PLAN.md), and [verification status](VERIFICATION.md). Independent input-quality evaluation and native host compatibility remain unproven.
