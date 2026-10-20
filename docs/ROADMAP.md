# Roadmap

SI is currently a development preview. Checked items have implementations; unchecked items remain planned. Automated engine coverage does not replace host-app verification.

## Foundation — included

- [x] One InputMethodKit input source without internal language modes.
- [x] Persistent English and Simplified Chinese language preferences.
- [x] Unified candidate engine with ambiguity preservation and literal fallback.
- [x] Offline English and Chinese vocabularies, with documented origins and coverage limits.
- [x] Multi-source English vocabulary maintenance, pinned imports, local overrides, source tracing and scheduled upstream audits.
- [x] Selected annotated Rime Ice Chinese character/base vocabulary, preserved SI entries, explicit weighting, local overrides and shared upstream audits.
- [x] Native marked text, candidate presentation, and commit/cancel integration.
- [x] English settings UI with a live candidate preview.
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
- [x] Opt-in local frequency/recency learning with pause, per-entry deletion, clear, expiry, and bounded persistence.
- [x] Existing single-language preferences influence internal tokens with bounded, length-weighted scoring and a separate base beam.
- [x] Optional previous-word pair ranking across languages, with shared retention/deletion controls.
- [x] Unified local probability scoring, English corpus-frequency priors and limited Chinese character-boundary backoff.
- [ ] Broader sentence-level context scoring and representative independent input-quality evaluation.
- [x] Composition-caret movement and whole-character forward/backward deletion with UTF-16 marked offsets.
- [x] Editable punctuation/symbols by default, optional punctuation confirmation, and no-learning delimiter commits.
- [ ] Real-host verification of punctuation, numbers, URLs, identifiers, and code entry.
- [ ] Preserve exact literal text with a clear, discoverable selection path.

## Reliability and distribution

- [ ] Host-app compatibility matrix, including browsers, editors, Terminal, and office apps.
- [ ] Tests for focus changes, secure fields, marked-text ranges, candidate paging, and multiple displays.
- [ ] Keyboard-only and VoiceOver verification, dark mode, and high-contrast checks.
- [ ] Resolve the duplicate secondary “SI” name in macOS's input-source list, if supported by public input-method metadata; preserve one source, its identifier, and its primary name.
- [ ] Latency and memory benchmarks using realistic lexicons.
- [x] Reproducible Release-mode synthetic candidate-generation benchmark with a full learning profile.
- [ ] Signed and notarized releases, installer/update flow, and recovery instructions.
- [ ] Document support policy and release process before the first stable release.

## Additional languages

- [ ] Generalize language preference storage and provider registration as languages are added.
- [ ] Add providers based on demonstrated user needs and compatible licensed data.
- [x] User phrase dictionary with explicit editing, import/export, and retention controls.
- [x] Optional short-context adaptation with client-local state and tested timeout/reset boundaries.
- [x] Personal phrase nodes inside longer compositions with fanout/output bounds and learning exclusion.
- [ ] Native focus-boundary verification and internal pair/sentence context scoring.

Remote inference and keystroke telemetry are not part of the current design. Any proposal that sends typed content off-device requires an explicit product and privacy discussion.
