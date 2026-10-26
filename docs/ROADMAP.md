# Roadmap

SI is currently a development preview. Checked items have implementations; unchecked items remain planned. Automated engine coverage does not replace host-app verification.

## Chinese migration — 2026-10-21

The current worktree replaces the historical Chinese/mixed decoder with a Swift MSIME adaptation and an SI-maintained dictionary. Full/prefix/initial lookup, spelling aliases, word-lattice search and word bigram/trigram ranking are written. The user authorized validation on October 22. Builds pass, while full regressions and Chinese quality remain unresolved; live host checks remain unverified. MSIME quality parity is unproven; optional general typo paths and neural reranking remain incomplete. Bounded complete-Pinyin/English lexical paths are connected, including `woxiangyaodeploy`; mixed initials and Chinese-tail completion remain incomplete. The checked historical Chinese/mixed milestones below describe the previous implementation, not verification of this migration. See [the implementation plan](IMPLEMENTATION_PLAN.md) and [algorithm study](MSIME_ALGORITHM.md).

The October 22 dictionary consolidation removes old Chinese sources and their maintenance adapter. English now has the same maintained weighted snapshots, public SI overlay, SQLite schema and relative-frequency weight unit as Chinese. Original English import provenance and functionality are retained; complete-candidate calibration remains separate work. Mixed lexical integration now queries those same dictionaries.

## Foundation — included

- [x] One InputMethodKit input source without internal language modes.
- [x] Persistent English and Simplified Chinese language preferences.
- [x] Unified candidate engine with ambiguity preservation and literal fallback.
- [x] Offline MSIME Chinese dictionary with pinned provenance and a public SI correction overlay.
- [x] Shared Chinese/English SQLite dictionary format, fixed relative-frequency weight unit, pinned weighted snapshots and SI-owned public overlays.
- [x] Multi-source English import provenance, pinned imports, source tracing and scheduled upstream audits.
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
- [x] Incomplete final mixed-word prediction and bounded preservation of unrecognized spans.
- [ ] Broader unknown-word/language-boundary detection beyond bounded lexical heuristics.
- [x] Opt-in app-scoped frequency/recency learning with pause, per-entry deletion, clear, expiry, and bounded persistence.
- [x] Independently opted-in app vocabulary and Return-delimited history completion, local bounded storage, per-app pause and scoped deletion.
- [ ] Native app-vocabulary/history verification, including WeChat, editors, Terminal, focus changes, keyboard/mouse selection and accessibility.
- [x] Existing single-language preferences influence internal tokens with bounded, length-weighted scoring and a separate base beam.
- [x] Shared heuristic word/spelling/transition scoring across Chinese, English and mixed candidates, with retained Chinese word-context tables.
- [x] Full-input prefix comparison with bounded continuation projection, exact source/output alignment, explicit confirmation cost and actual-shortlist quality reporting.
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

- [x] Independent from-scratch 0.403B encoder–decoder framework with training/resume, train-only tokenizer, evaluation/comparison and inference export.
- [x] Maintained static CSV groups under explicit train/validation/test directories, source snapshots/checksums, duplicate/leakage validation and no dynamic generation.
- [x] Small CPU workflow and regression coverage, including learned conversion, exact resume and MPS numerical mask checks.
- [x] Removal of obsolete generated data, seed/generator/importer code, configs and their test artifacts; existing trained weights retained for inference.
- [ ] Representative licensed training corpus and independent real-error evaluation.
- [ ] Full training and measured conversion/latency/memory quality.
- [ ] Native deployment with language-aware candidates, exact alignment and host verification.

See [the experiment framework](../llm/README.md). The data/tooling and small-model checks do not establish production input-method quality.

## Retired options

The separate global Personal learning and previous-word pair UI/storage feature was removed on October 23, 2026 in favor of app vocabulary and app history. Core frequency/context ranking primitives remain for reuse and fixtures; the app enables no shared-profile fallback or previous-word learning. Old shared files are left inactive until explicitly deleted through Settings.
