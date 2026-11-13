# Contributing to SI

Thanks for helping build SI. The product principle is simple: users enable languages in Settings and type through one input source. Ambiguous input should expose choices from all enabled languages.

## Development

1. Install Xcode 26 or later and select it as the active developer directory.
2. Install Rust 1.89 or later and add the Apple Silicon and Intel macOS targets for universal builds. Open `mac/SI.xcodeproj` and choose the shared SI scheme. Xcode generates the Rust lexicon from the tracked CSV files.
3. For macOS app code changes beyond vocabulary maintenance, run `./scripts/test.sh` and `./scripts/build.sh` before submitting.
4. For input-method changes, complete the relevant checks in [docs/TESTING.md](docs/TESTING.md).

The Swift package tests the same core files compiled by the macOS app. Use Swift 6 language mode. Keep language providers independent of AppKit and SwiftUI. Add focused tests for candidate ranking, ambiguity, state transitions, or regressions when behavior changes.

For Rust changes, run the [Cargo checks](README.md#rust-engine-workspace).
Use `si-cli` in the same guide for local Rust lexicon and corpus imports.
Use synthetic data for the performance benchmark.

For dictionary changes, edit `Data/Chinese/*.csv` and `Data/English/*.csv`.
Keep the `text,reading,weight` header and explicit nonnegative integer counts;
repeated exact identities sum across all files. Validate the Rust dictionary with `si-cli lexicon build` and see
[vocabulary maintenance](README.md#vocabulary-maintenance).
Retain source attribution/licenses with the dictionary resources. New external
sources still require the review below. Private phrases, learning and history
are never ordinary dictionary inputs. For vocabulary-only changes, validate
the data and regenerate resources as needed; do not run app regression suites
or builds unless requested.

## Training data and Git LFS

Install Git LFS (`brew install git-lfs` on macOS), then run `git lfs install --local` and `git lfs pull` in the checkout. The repository's `.gitattributes` routes CSV files under `llm/pinyin_to_text/data/csv/`, including nested groups, through LFS. Edit and stage these files normally; commit their LFS pointers together with any provenance updates. `git push` uploads the associated data through the LFS pre-push hook. Check `git lfs status` and `git lfs fsck` before pushing data changes.

Keep prepared datasets, checkpoints, reports and private archives ignored. LFS is storage for the maintained public CSVs; it does not change their license, retention or permitted sources. New clones need Git LFS to materialize the data. Existing Git history retains its original blobs; this forward migration does not rewrite published commits.

## Local corpus and model artifacts

Keep the maintained dictionary CSVs, manifests and attribution in Git.
Generate Rust dictionary and word-gram snapshots locally.

Downloaded archives, generated lexical tables, prepared training bundles, virtual environments, caches, checkpoints, exports and reports stay local under the ignored paths. Recreate them with the explicit commands in [the corpus guide](corpus/README.md#download-prepare-and-verify) and each [model guide](llm/README.md). Use a fresh output directory when preparing an immutable bundle. Reviewed corpus metadata referenced by `sources.lock.json` stays tracked so a fresh checkout can validate sources before downloading.

To stop tracking an artifact accidentally added earlier, use `git rm --cached` with its exact path and commit the removal together with its ignore rule. This preserves the local copy; later downloads or regeneration remain ignored. It does not remove blobs from earlier commits or shrink existing Git history. Do not use `git add -f` for these artifacts. Before committing, `git ls-files -ci --exclude-standard -- corpus llm` should return no paths.

## Pull requests

- Describe the user-visible problem, resulting behavior, and validation performed.
- Keep changes focused and use English for code identifiers, comments, documentation, source localization keys, issues, and pull requests. Keep app translations in the matching `Localizable.strings` resources with identical keys and format arguments. Translations, language examples and lexicons use their native scripts.
- Do not introduce a current-language mode, a language toggle shortcut, or a ranking rule that silently hides other enabled languages.
- Keep the original input available, including unknown words and identifiers.
- Keep typed content out of diagnostic logs. Send input and host context to the selected AI provider only within the independent [AI completion consent boundary](docs/PRIVACY.md#ai-completion). Input History retains SI submissions under its own opt-in. Sentence History separately opts into bounded Return-time text-client snapshots in all conversion-enabled apps. Keep both history stores local and separate from ranking/training, with secure-input, deletion and storage-error safeguards. Explicitly shared exports may become private offline candidate data through the documented receiver workflow. Never commit contributions, infer redistribution rights or silently append them to maintained datasets.
- Discuss third-party engines, dictionaries, models, and large dependencies in an issue first. Include their license and data provenance.
- Leave signing identities, provisioning profiles, user-specific Xcode state, and build products out of commits.

By contributing, you agree that your contribution will be distributed under the repository's existing GPLv3 license. Do not include material you lack permission to distribute.

## Bug reports and ideas

Use the GitHub issue templates. For typing bugs, include macOS/Xcode versions, host application, enabled languages, a non-sensitive input example, the expected candidates or output, and the actual result.

Treat other contributors respectfully. Discuss technical decisions with concrete examples and reproducible evidence.
