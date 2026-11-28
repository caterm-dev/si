# Roadmap

SI is currently a development preview. Checked items have implementations; unchecked items remain planned. Automated engine coverage does not replace host-app verification.

## macOS conversion migration — 2026-11

The macOS app uses the Rust decoder and bundles `main.silex` with its
paired `words.sigram` model. The app uses Rust for
lexical search, final candidate merging, ordering and window shortlisting.
Swift owns InputMethodKit, client-local session state and candidate-window UI.
The presentation policy is reusable by future platforms; iOS, iPadOS and Linux
input-method frontends are not implemented.
Native host behavior and parity with the earlier Chinese ranking still
require verification. See [architecture](ARCHITECTURE.md#rust-conversion)
and [bridge checks](TESTING.md#automated-checks).

## Foundation — included

- [x] One InputMethodKit input source without internal language modes.
- [x] Persistent English and Simplified Chinese language preferences.
- [x] Unified candidate engine with ambiguity preservation and literal fallback.
- [x] Platform-independent Rust final ordering and shortlist policy shared by the macOS adapter and CLI.
- [x] Length-based constructed-result window budget: 6 output characters allow 3 choices, 7–8 allow 2, and 9 or more allow 1, shared by sentences, prefixes and completions; no statistical-leader reservations.
- [x] Maintained Chinese and English category CSVs derived from pinned upstream data and SI additions.
- [x] Shared Rust lexicon compiler with explicit integer counts and an optional paired word-gram model.
- [x] Conservatively group existing Chinese vocabulary into base plus geography, organizations, technology, science, medicine, culture/sports, movie and game without changing effective rows or weights.
- [x] Curate paired Chinese/English titles for 400 selected films from 2007–2026, preserving older movie vocabulary and adding English title typing keys.
- [ ] Further semantic review, finer categories and broader film coverage beyond the initial movie selection.
- [x] Native marked text, candidate presentation, and commit/cancel integration.
- [x] English and Simplified Chinese app interface, following macOS app-language preferences independently of input languages.
- [x] Shared-core tests, build scripts, installation instructions, and website CI.

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
- [x] Local learning from Return field snapshots persists the Rust user lexicon and word grams.
- [x] Independent default-off App Learning settings and activity-triggered background AX sampling with a global 30-second cooldown into private per-app lexical/word-gram pairs, with one previous snapshot per app, append-only paragraph differences, one fixed file pair, automatic capacity pruning and explicit deletion; storage only.
- [ ] Native App Learning timer, AX coverage, secure/direct-input, permission and Settings accessibility verification.
- [ ] Integrate app-local models into candidate search/ranking after separate design and verification.
- [ ] Native sentence learning verification across compatible host fields, focus changes, secure input and Settings accessibility.
- [x] Remove App History recording/completion; migrate app archives to global vocabulary-only schema 4, merging app counts, preserving schema-3 evidence and resetting older ambiguous ranking evidence.
- [x] Independently opted-in permanent Input History with exact per-submission spelling/output, repeat preservation, local SQLite pages, search, explicit deletion and error/retry controls; no candidate/training integration.
- [x] User-controlled single-file history export, one direct save action, checksum-validated offline restoration and unsplit training candidates without purpose flags; no automatic transfer/training.
- [ ] Native Input History export save/cancel/accessibility verification.
- [ ] Native Input History verification, including consent, secure input, prefix/automatic/literal submissions, host reentry, keyboard/VoiceOver and appearance.
- [ ] Native app-vocabulary verification, including WeChat, editors, Terminal, focus changes, keyboard/mouse selection and accessibility.
- [x] Existing single-language preferences influence internal tokens with bounded, length-weighted scoring and a separate base beam.
- [x] Shared heuristic word/spelling/transition scoring across Chinese, English and mixed candidates, with optional paired word grams inside the composition.
- [x] Local last-sentence word-gram scoring from the preceding text of compatible InputMethodKit clients.
- [ ] Native field-context verification across hosts, focus changes and secure input.
- [x] Consumed-spelling-only prefix ranking with a shared matched-input coverage reward, no suffix conversion estimate, learning discount or extra confirmation cost; exact prefix commits and four leading hypotheses followed by word choices in the window.
- [ ] Broader cross-language quality calibration against representative input.
- [x] Language-specific word/syllable spelling channels and bounded full-spelling search protection.
- [ ] Broader sentence-level context scoring and representative independent input-quality evaluation.
- [x] Composition-caret movement and whole-character forward/backward deletion with UTF-16 marked offsets.
- [x] Manual-only prefix confirmation; automatic stable-prefix confirmation and its setting/timer have been retired.
- [ ] Native manual-prefix, focus and marked-remainder verification across representative hosts.
- [x] Editable punctuation/symbols by default, opt-in, default-off language-labeled common punctuation candidates, optional punctuation confirmation, and no-learning delimiter commits.
- [ ] Real-host verification of punctuation, numbers, URLs, identifiers, and code entry.
- [x] Opt-in direct key passthrough by client application, with searchable application discovery and persistent app rules.
- [x] Separate explicit Accessibility/Screen Recording permission actions for future experiments, without changing input behavior.
- [x] Add manually requested AI completion with bounded IMK field text, a current-window screenshot, a separate candidate row and a second Tab for acceptance.
- [ ] Verify AI completion with the three live backends, native hosts, and VoiceOver.
- [ ] Native experimental permission dialogs/revocation and Settings keyboard/VoiceOver verification.
- [ ] Unified input-control recognition and automatic field-based behavior.
- [ ] Native direct-input switching, pending-composition, shortcut and app-memory verification.
- [x] Preserve exact literal text with a clear, discoverable selection path.

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

Ordinary conversion is local. Optional AI Completion has its own consent and an explicit Tab trigger. See the [privacy policy](PRIVACY.md#ai-completion).

## Offline model experiments

- [x] Independent 7.4M causal character-LM baseline with whole-document corpus preparation, train-only vocabulary, grouped splits, strict resume, held-out token-loss and standalone supplied-candidate scoring, plus inference-only export.
- [x] Offline 15.6M character-student configuration, explicit source-linked document/pool preparation, local Qwen 0.5B scoring, candidate-level distillation, strict CPU-tested resume and Python/Rust export; only tiny synthetic workflows are verified.
- [ ] Reviewed 15.6M student datasets, formal pretraining/distillation, device validation and independent ranking/typing-latency evidence.
- [x] Local 30,000-step small checkpoint and explicit offline FP32 Core ML conversion.
- [x] Optional bounded small-model reranking during macOS conversion, independent of Pinyin correction.
- [ ] Redesign native AI integration; the former original/AI comparison is removed.
- [ ] Independent ranking-quality evidence, hard-negative fine-tuning, quantization and native host/VoiceOver verification for future native AI integration.
- [x] Independent from-scratch encoder-decoder framework with training/resume, train-only tokenizer, evaluation/comparison and inference export, with a 19.7M model preset for explicit Pinyin syllables and optional context.
- [x] Maintained static CSV groups under explicit train/validation/test directories, source snapshots/checksums, duplicate/leakage validation and no dynamic generation.
- [x] Tiny CPU workflow and regression coverage, including learned conversion, exact resume, MPS numerical masks and nonzero-dropout checkpoint RNG/gradient checks; bounded 19.7M memorization check.
- [x] Removal of obsolete generated data, seed/generator/importer code, configs and their test artifacts; existing trained weights retained for inference.
- [ ] Representative licensed training corpus and independent real-error evaluation.
- [ ] Full training and measured conversion/latency/memory quality.
- [ ] Native deployment with language-aware candidates, exact alignment and host verification.

See [the experiment framework](../llm/README.md). The data/tooling and small-model checks do not establish production input-method quality.

## Retired options

The separate global Personal learning and previous-word pair UI/storage feature was removed on October 23, 2026 in favor of app-scoped vocabulary (App History was subsequently removed on October 27, 2026); on November 1, 2026, that app archive became global Personal Learning with exact-choice priority, no per-app learning controls and no age expiry/decay. Core frequency/context ranking primitives remain for reuse and fixtures; the separate retired archive remains inactive, and the app enables no previous-word learning. Old shared files are left inactive until explicitly deleted through Settings.
