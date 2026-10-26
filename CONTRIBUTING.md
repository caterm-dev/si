# Contributing to SI

Thanks for helping build SI. The product principle is simple: users enable languages in Settings and type through one input source. Ambiguous input should expose choices from all enabled languages.

## Development

1. Install Xcode 26 or later and select it as the active developer directory.
2. Open `mac/SI.xcodeproj` and choose the shared SI scheme.
3. Run `./scripts/test.sh` and `./scripts/build.sh` before submitting a change.
4. For input-method changes, complete the relevant checks in [docs/TESTING.md](docs/TESTING.md).

The Swift package tests the same core files compiled by the macOS app. Use Swift 6 language mode. Keep language providers independent of AppKit and SwiftUI. Add focused tests for candidate ranking, ambiguity, state transitions, or regressions when behavior changes.

For dictionary changes, follow the [Chinese maintenance workflow](docs/CHINESE_VOCABULARY.md) or [English maintenance](docs/ENGLISH_VOCABULARY.md). Both use pinned weighted snapshots, an SI-owned `si-entries.json` overlay and the shared SQLite/weight contract in `Data/DictionaryFormat.json`. Keep snapshots, provenance, licenses and generated resources together. Run `python3 scripts/msime_dictionary.py build --check`, `python3 scripts/english_dictionary.py build --check`, `./scripts/vocabulary.sh build --check`, `python3 scripts/ranking.py --check`, and the Python maintenance tests before the shared-core checks. Private personal phrases and learning archives are separate from public dictionary maintenance.

## Training data and Git LFS

Install Git LFS (`brew install git-lfs` on macOS), then run `git lfs install --local` and `git lfs pull` in the checkout. The repository's `.gitattributes` routes CSV files under `llm/data/csv/`, including nested groups, through LFS. Edit and stage these files normally; commit their LFS pointers together with any provenance updates. `git push` uploads the associated data through the LFS pre-push hook. Check `git lfs status` and `git lfs fsck` before pushing data changes.

Keep prepared datasets, checkpoints, reports and private archives ignored. LFS is storage for the maintained public CSVs; it does not change their license, retention or permitted sources. New clones need Git LFS to materialize the data. Existing Git history retains its original blobs; this forward migration does not rewrite published commits.

## Pull requests

- Describe the user-visible problem, resulting behavior, and validation performed.
- Keep changes focused and use English for code identifiers, comments, documentation, source localization keys, issues, and pull requests. Keep app translations in the matching `Localizable.strings` resources with identical keys and format arguments. Translations, language examples and lexicons use their native scripts.
- Do not introduce a current-language mode, a language toggle shortcut, or a ranking rule that silently hides other enabled languages.
- Keep the original input available, including unknown words and identifiers.
- Do not log typed content or send it to external services.
- Discuss third-party engines, dictionaries, models, and large dependencies in an issue first. Include their license and data provenance.
- Leave signing identities, provisioning profiles, user-specific Xcode state, and build products out of commits.

By contributing, you agree that your contribution will be distributed under the repository's existing GPLv3 license. Do not include material you lack permission to distribute.

## Bug reports and ideas

Use the GitHub issue templates. For typing bugs, include macOS/Xcode versions, host application, enabled languages, a non-sensitive input example, the expected candidates or output, and the actual result.

Treat other contributors respectfully. Discuss technical decisions with concrete examples and reproducible evidence.
