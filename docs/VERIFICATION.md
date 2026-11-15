# Implementation verification

## Rust conversion cleanup — November 13, 2026

- Cargo formatting, Clippy with warnings denied, and the Rust workspace tests
  passed.
- SwiftPM ran 388 tests using `./scripts/test.sh --disable-sandbox`. The run
  recorded eight known assertions for the same missing composed Chinese
  candidate. [Known recall miss](TESTING.md#known-rust-recall-misses)
- The arm64/x86_64 Release app built and passed resource inspection. The
  standalone lexicon compiled from the tracked CSVs matched the bundled
  dictionary byte for byte.
- Packaging and installer fixtures (65), vocabulary fixtures (13), offline
  corpus fixtures (63), ranking dataset fixtures (4), input-history tool
  fixtures (7) and small-model fixtures (19) passed. The 220-query dataset
  reproduced byte for byte.
- Native InputMethodKit typing, registration, focus changes, VoiceOver and
  host-app compatibility remain open. [Host checklist](TESTING.md#manual-input-method-verification)

Earlier measurements and migration records are available from the Git
revision that removed the Swift conversion stack.

```sh
git show 0509cb3:docs/TESTING.md
git show 0509cb3:docs/VERIFICATION.md
git show 0509cb3:docs/IMPLEMENTATION_PLAN.md
```
