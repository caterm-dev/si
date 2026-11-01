# Roadmap

SI is currently a development preview. Checked items have implementations; unchecked items remain planned. Automated engine coverage does not replace host-app verification.

## Chinese migration — 2026-10-21

The current worktree replaces the historical Chinese/mixed decoder with a Swift MSIME adaptation and an SI-maintained dictionary. Full/prefix/initial lookup, spelling aliases, word-lattice search and word bigram/trigram ranking are written. The user authorized validation on October 22. Builds pass, while full regressions and Chinese quality remain unresolved; live host checks remain unverified. MSIME quality parity is unproven; optional general typo paths and neural reranking remain incomplete. Bounded complete-Pinyin/English lexical paths are connected, including `woxiangyaodeploy`; mixed initials and Chinese-tail completion remain incomplete. The checked historical Chinese/mixed milestones below describe the previous implementation, not verification of this migration. See [the implementation plan](IMPLEMENTATION_PLAN.md) and [algorithm study](MSIME_ALGORITHM.md).

The October 22 dictionary consolidation removes old Chinese sources and their maintenance adapter. English shares the Chinese SQLite schema. The October 29 Wanxiang replacement supersedes the former relative-frequency weight unit with raw upstream ranking weights. The October 27 source migration places both effective dictionaries in SI-maintained `base.csv` files, supports additional category CSVs and centralizes source-level provenance in `Data/Vocabulary/meta.json`; source-level metadata and notices remain attribution records, while superseded wordlists/import pipelines are deleted. Original English import provenance and functionality are retained; complete-candidate calibration remains separate work. Mixed lexical integration now queries those same dictionaries.

## Foundation — included

- [x] One InputMethodKit input source without internal language modes.
- [x] Persistent English and Simplified Chinese language preferences.
- [x] Unified candidate engine with ambiguity preservation and literal fallback.
- [x] Pinned Wanxiang Chinese/English bases and normal Chinese category dictionaries, with an offline converter and preserved local category data.
- [x] Shared Chinese/English category CSV compiler, base categories, source-level metadata, SQLite format and versioned upstream-weight weight unit.
- [x] Conservatively group existing Chinese vocabulary into base plus geography, organizations, technology, science, medicine, culture/sports, movie and game without changing effective rows or weights.
- [x] Curate paired Chinese/English titles for 400 selected films from 2007–2026, preserving older movie vocabulary and adding English title typing keys.
- [ ] Further semantic review, finer categories and broader film coverage beyond the initial movie selection.
- [x] Multi-source English bootstrap provenance retained inline in metadata, with source versions, filtering and full attribution; superseded import data/tools removed.
- [x] Selected annotated Rime Ice Chinese character/base vocabulary, preserved SI entries, explicit weighting, local overrides and shared upstream audits.
- [x] Native marked text, candidate presentation, and commit/cancel integration.
- [x] English and Simplified Chinese app interface, following macOS app-language preferences independently of input languages.
- [x] Shared-core tests, build scripts, installation instructions, and CI configuration.

## Useful everyday input

- [x] Bounded word-lattice decoding, stored-phrase initials, phrase construction, and explicit apostrophe boundaries.
- [x] Mixed full/initial abbreviations and prefix confirmation with an editable remainder.
- [ ] Broader original vocabulary coverage, fuzzy decoding, and independent quality evaluation.
- [ ] English vocabulary, capitalization, completion, and correction improvements.
- [x] Continuous mixed composition of known English words and Chinese readings.
- [x] Continuous English lexical segmentation with spaced word candidates, preserved casing, and final-word completion.
- [ ] Integrate large-model conversion with local inference, bounded candidate generation, exact literal fallback and independent quality/host verification.
- [x] Incomplete final mixed-word prediction and bounded preservation of unrecognized spans.
- [ ] Broader unknown-word/language-boundary detection beyond bounded lexical heuristics.
- [x] Opt-in global Personal Learning with shared usage/correction counts, neutral first choices, one-correction exact-spelling priority, bounded frequency rewards and global management; no per-app learning controls, decay or age expiry.
- [x] Remove App History recording/completion; migrate app archives to global vocabulary-only schema 4, merging app counts, preserving schema-3 evidence and resetting older ambiguous ranking evidence.
- [x] Independently opted-in permanent Input History with exact per-submission spelling/output, repeat preservation, local SQLite pages, search, explicit deletion and error/retry controls; no candidate/training integration.
- [x] User-controlled single-file history export, one direct save action, checksum-validated offline restoration and unsplit training candidates without purpose flags; no automatic transfer/training.
- [ ] Native Input History export save/cancel/accessibility verification.
- [ ] Native Input History verification, including consent, secure input, prefix/automatic/literal submissions, host reentry, keyboard/VoiceOver and appearance.
- [ ] Native app-vocabulary verification, including WeChat, editors, Terminal, focus changes, keyboard/mouse selection and accessibility.
- [x] Existing single-language preferences influence internal tokens with bounded, length-weighted scoring and a separate base beam.
- [x] Shared heuristic word/spelling/transition scoring across Chinese, English and mixed candidates, without corpus context; former MSNG tables are archived outside the App.
- [x] Consumed-spelling-only prefix ranking with a shared matched-input coverage reward, no suffix conversion estimate, learning discount or extra confirmation cost; exact prefix commits and four leading hypotheses followed by word choices in the window.
- [ ] Broader cross-language quality calibration against representative input.
- [x] Language-specific word/syllable spelling channels and bounded full-spelling search protection.
- [ ] Broader sentence-level context scoring and representative independent input-quality evaluation.
- [x] Composition-caret movement and whole-character forward/backward deletion with UTF-16 marked offsets.
- [x] Optional automatic stable-prefix confirmation from continued typing or a pause, retaining an editable ending and excluding implicit learning.
- [ ] Native automatic-confirmation timer/focus verification and broader independent false-confirmation evaluation.
- [x] Editable punctuation/symbols by default, opt-in, default-off language-labeled common punctuation candidates, optional punctuation confirmation, and no-learning delimiter commits.
- [ ] Real-host verification of punctuation, numbers, URLs, identifiers, and code entry.
- [x] Opt-in direct key passthrough by client application, with searchable application discovery and persistent app rules.
- [ ] Native direct-input switching, pending-composition, shortcut and app-memory verification.
- [ ] Preserve exact literal text with a clear, discoverable selection path.

## Reliability and distribution

- [ ] Host-app compatibility matrix, including browsers, editors, Terminal, and office apps.
- [ ] Tests for focus changes, secure fields, marked-text ranges, candidate paging, and multiple displays.
- [ ] Keyboard-only and VoiceOver verification, dark mode, and high-contrast checks.
- [ ] Resolve the duplicate secondary “SI” name in macOS's input-source list, if supported by public input-method metadata; preserve one source, its identifier, and its primary name.
- [ ] Latency and memory benchmarks using realistic lexicons.
- [x] Reproducible Release-mode synthetic candidate-generation benchmark with a full learning profile.
- [ ] Signed and notarized releases, installer/update flow, and recovery instructions.
- [x] Manual Sparkle update checks in Settings/input menu, signed app archives and separate R2 update feeds.
- [ ] Native signed input-method update/relaunch, registration recovery and host-compatibility verification.
- [ ] Document support policy and release process before the first stable release.

## Additional languages

- [ ] Generalize language preference storage and provider registration as languages are added.
- [ ] Add providers based on demonstrated user needs and compatible licensed data.
- [x] User phrase dictionary with explicit editing, import/export, and retention controls.
- [x] Personal phrase nodes inside longer compositions with fanout/output bounds and learning exclusion.
- [ ] Native focus-boundary verification and internal pair/sentence context scoring.

Remote inference and keystroke telemetry are not part of the current design. Any proposal that sends typed content off-device requires an explicit product and privacy discussion.

## Offline model experiments

- [x] Independent 7.4M causal character-LM baseline with whole-document corpus preparation, train-only vocabulary, grouped splits, strict resume, held-out token-loss and fixed-pool candidate evaluation, plus inference-only export.
- [ ] Formal small-reranker training, independent ranking-quality evidence, hard-negative fine-tuning, quantization and native integration.
- [x] Independent from-scratch encoder-decoder framework with training/resume, train-only tokenizer, evaluation/comparison and inference export; 19.7M Pinyin character/word defaults with the earlier 0.403B experiment retained separately.
- [x] Maintained static CSV groups under explicit train/validation/test directories, source snapshots/checksums, duplicate/leakage validation and no dynamic generation.
- [x] Tiny CPU workflow and regression coverage, including learned conversion, exact resume, MPS numerical masks and nonzero-dropout checkpoint RNG/gradient checks; bounded 19.7M memorization check.
- [x] Removal of obsolete generated data, seed/generator/importer code, configs and their test artifacts; existing trained weights retained for inference.
- [ ] Representative licensed training corpus and independent real-error evaluation.
- [ ] Full training and measured conversion/latency/memory quality.
- [ ] Native deployment with language-aware candidates, exact alignment and host verification.

See [the experiment framework](../llm/README.md). The data/tooling and small-model checks do not establish production input-method quality.

## Retired options

The separate global Personal learning and previous-word pair UI/storage feature was removed on October 23, 2026 in favor of app-scoped vocabulary (App History was subsequently removed on October 27, 2026); on November 1, 2026, that app archive became global Personal Learning with exact-choice priority, no per-app learning controls and no age expiry/decay. Core frequency/context ranking primitives remain for reuse and fixtures; the separate retired archive remains inactive, and the app enables no previous-word learning. Old shared files are left inactive until explicitly deleted through Settings.
