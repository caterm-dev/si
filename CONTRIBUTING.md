# Contributing to SI

Thanks for helping build SI. The product principle is simple: users enable languages in Settings and type through one input source. Ambiguous input should expose choices from all enabled languages.

## Development

1. Install Xcode 26 or later and select it as the active developer directory.
2. Run `python3 scripts/csv_dictionary.py build` to generate both local SQLite dictionaries from the tracked CSV sources, then open `mac/SI.xcodeproj` and choose the shared SI scheme.
   Generate the dictionaries before the first build/test in a fresh clone and after editing vocabulary. No language-model staging is required.
3. Run `./scripts/test.sh` and `./scripts/build.sh` before submitting a change.
4. For input-method changes, complete the relevant checks in [docs/TESTING.md](docs/TESTING.md).

The Swift package tests the same core files compiled by the macOS app. Use Swift 6 language mode. Keep language providers independent of AppKit and SwiftUI. Add focused tests for candidate ranking, ambiguity, state transitions, or regressions when behavior changes.

For dictionary changes, edit SI's [categorized CSV collection](Data/Vocabulary/README.md). Chinese entries are grouped into [base and eight domain files](Data/Vocabulary/chinese/README.md), with common/unclassified vocabulary in base; English has base, movie and domain files; see the [movie maintenance guide](Data/Vocabulary/MOVIES.md) for paired titles and typing keys. New categories are separate files. Keep source-level provenance in `Data/Vocabulary/meta.json`, use only text/reading/weight columns, and retain source notices/licenses. Both languages compile to the shared SQLite/weight contract in `Data/DictionaryFormat.json`. Run `python3 scripts/csv_dictionary.py build --check`, `python3 scripts/msime_dictionary.py build --check` (including context hashes), and `python3 -m unittest discover -s Tests/VocabularyTests -v` before the shared-core checks. The current bases come from a pinned Wanxiang data revision through `scripts/wanxiang_dictionary.py`; see `Data/Vocabulary/Wanxiang/README.md` for explicit fetch/convert/check commands. Conversion preserves category files, source weights and a reviewable exclusions report. The former English import/frequency tools and data remain removed. `python3 scripts/ranking.py --check` still verifies retained attribution and synthetic calibration without those old wordlists. Private phrases and learning archives are never dictionary inputs. See [Chinese maintenance](docs/CHINESE_VOCABULARY.md) and [English maintenance](docs/ENGLISH_VOCABULARY.md).

## Training data and Git LFS

Install Git LFS (`brew install git-lfs` on macOS), then run `git lfs install --local` and `git lfs pull` in the checkout. The repository's `.gitattributes` routes CSV files under `llm/pinyin_to_text/data/csv/`, including nested groups, through LFS. Edit and stage these files normally; commit their LFS pointers together with any provenance updates. `git push` uploads the associated data through the LFS pre-push hook. Check `git lfs status` and `git lfs fsck` before pushing data changes.

Keep prepared datasets, checkpoints, reports and private archives ignored. LFS is storage for the maintained public CSVs; it does not change their license, retention or permitted sources. New clones need Git LFS to materialize the data. Existing Git history retains its original blobs; this forward migration does not rewrite published commits.

## Local corpus and model artifacts

Keep the maintained application dictionary CSV sources in `Data/`, resource manifests and attribution in Git. Generated `.db`, `.sqlite` and `.sqlite3` files and their journal/WAL/shared-memory sidecars are ignored. Rebuild the runtime dictionaries offline with `python3 scripts/csv_dictionary.py build` before building or testing a fresh clone; `scripts/build.sh` and `scripts/test.sh` use these local resources without generating them. In `corpus/` and `llm/`, retain scripts, configurations, dependency pins, source locks, attribution, measured snapshot summaries, authored CSV sources and frozen regression fixtures. The static training CSVs have no general regeneration script and must remain available as source inputs.

Downloaded archives, generated lexical tables, prepared training bundles, virtual environments, caches, checkpoints, exports and reports stay local under the ignored paths. Recreate them with the explicit commands in [the corpus guide](corpus/README.md#download-prepare-and-verify) and each [model guide](llm/README.md). Use a fresh output directory when preparing an immutable bundle. Reviewed corpus metadata referenced by `sources.lock.json` stays tracked so a fresh checkout can validate sources before downloading.

To stop tracking an artifact accidentally added earlier, use `git rm --cached` with its exact path and commit the removal together with its ignore rule. This preserves the local copy; later downloads or regeneration remain ignored. It does not remove blobs from earlier commits or shrink existing Git history. Do not use `git add -f` for these artifacts. Before committing, `git ls-files -ci --exclude-standard -- corpus llm` should return no paths.

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
