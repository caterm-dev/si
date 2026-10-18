# Roadmap

SI is currently a development scaffold. Items below are planned, not shipped features.

## Foundation — included

- [x] One InputMethodKit input source without internal language modes.
- [x] Persistent English and Simplified Chinese language preferences.
- [x] Unified candidate engine with ambiguity preservation and literal fallback.
- [x] Original offline demonstration vocabularies.
- [x] Native marked text, candidate presentation, and commit/cancel integration.
- [x] English settings UI with a live candidate preview.
- [x] Shared-core tests, build scripts, installation instructions, and CI configuration.

## Useful everyday input

- [ ] Select a GPL-compatible production Pinyin engine and document dictionary provenance.
- [ ] Full syllable decoding, initials, phrase composition, and apostrophe semantics.
- [ ] English vocabulary, capitalization, completion, and correction improvements.
- [ ] Automatic segmentation of continuous mixed Chinese/English input.
- [ ] Context-aware ranking across languages without suppressing ambiguous alternatives.
- [ ] Reliable punctuation, numbers, URLs, identifiers, and code entry.
- [ ] Preserve exact literal text with a clear, discoverable selection path.

## Reliability and distribution

- [ ] Host-app compatibility matrix, including browsers, editors, Terminal, and office apps.
- [ ] Tests for focus changes, secure fields, marked-text ranges, candidate paging, and multiple displays.
- [ ] Keyboard-only and VoiceOver verification, dark mode, and high-contrast checks.
- [ ] Latency and memory benchmarks using realistic lexicons.
- [ ] Signed and notarized releases, installer/update flow, and recovery instructions.
- [ ] Document support policy and release process before the first stable release.

## Additional languages

- [ ] Generalize language preference storage and provider registration as languages are added.
- [ ] Add providers based on demonstrated user needs and compatible licensed data.
- [ ] User dictionaries and optional local learning with explicit retention controls.

Remote inference and keystroke telemetry are not part of the current design. Any proposal that sends typed content off-device requires an explicit product and privacy discussion.
