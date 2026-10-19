# Contributing to SI

Thanks for helping build SI. The product principle is simple: users enable languages in Settings and type through one input source. Ambiguous input should expose choices from all enabled languages.

## Development

1. Install Xcode 26 or later and select it as the active developer directory.
2. Open `mac/SI.xcodeproj` and choose the shared SI scheme.
3. Run `./scripts/test.sh` and `./scripts/build.sh` before submitting a change.
4. For input-method changes, complete the relevant checks in [docs/TESTING.md](docs/TESTING.md).

The Swift package tests the same core files compiled by the macOS app. Use Swift 6 language mode. Keep language providers independent of AppKit and SwiftUI. Add focused tests for candidate ranking, ambiguity, state transitions, or regressions when behavior changes.

For vocabulary changes, follow the [English](docs/ENGLISH_VOCABULARY.md) or [Chinese](docs/CHINESE_VOCABULARY.md) maintenance workflow. Keep source snapshots, overrides, licenses and generated outputs together, and run `./scripts/vocabulary.sh build --check`, `./scripts/vocabulary.sh --language chinese build --check`, and the Python maintenance tests before the shared-core checks.

## Pull requests

- Describe the user-visible problem, resulting behavior, and validation performed.
- Keep changes focused and use English for code identifiers, comments, documentation, UI text, issues, and pull requests. Language examples and lexicons may use their native scripts.
- Do not introduce a current-language mode, a language toggle shortcut, or a ranking rule that silently hides other enabled languages.
- Keep the original input available, including unknown words and identifiers.
- Do not log typed content or send it to external services.
- Discuss third-party engines, dictionaries, models, and large dependencies in an issue first. Include their license and data provenance.
- Leave signing identities, provisioning profiles, user-specific Xcode state, and build products out of commits.

By contributing, you agree that your contribution will be distributed under the repository's existing GPLv3 license. Do not include material you lack permission to distribute.

## Bug reports and ideas

Use the GitHub issue templates. For typing bugs, include macOS/Xcode versions, host application, enabled languages, a non-sensitive input example, the expected candidates or output, and the actual result.

Treat other contributors respectfully. Discuss technical decisions with concrete examples and reproducible evidence.
