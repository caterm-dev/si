# English vocabulary maintenance

SI maintains English source files separately and queries one generated vocabulary. Source boundaries are for attribution, updates, and editorial control; they do not create input modes or Settings toggles. Chinese data has a separate [maintenance configuration](CHINESE_VOCABULARY.md), selected with `--language chinese`; existing commands still default to English.

## Current sources

| Source | Purpose | Initial words | Completion score |
| --- | --- | ---: | ---: |
| `scowl` | ESDB/SCOWL medium-size American English selection | 61,172 | 75 |
| `si-original` | All words from SI's original English vocabulary | 638 | 85 |
| `si-terms` | SI-maintained terminology and explicit coverage additions | 22 | 85 |

The initial merged result contains **61,216** case-insensitively unique words, including `subtitle` and `subtitles`. These are word forms, not headwords or a measured coverage score. Run `./scripts/vocabulary.sh stats` for current counts. Importing more words does not establish production ranking, correction, or host compatibility.

The initial SCOWL commit is `1e5b7d3a72f47a71da5d28686c1dd4b397178485`. The export selects size 50, American spelling `A`, variant level 1, the default category and POS class, and excludes abbreviations. SCOWL's POS classifications are incomplete, so this selection can still contain proper names and uncommon words. Only ASCII alphabetic forms of 2–64 letters are imported. Apostrophes, spaces, hyphens, accents, numbers, and standalone letter names are filtered rather than rewritten. SI's original `a` and `I` remain available. No diacritics are stripped and no text is silently transliterated.

`si-original` and `si-terms` are original SI data under GPLv3. The full upstream SCOWL copyright notice is retained in [the license directory](../Data/English/licenses/SCOWL.txt). SCOWL explicitly permits use, modification and redistribution of generated word lists while preserving its notices. Keep those permissive notices alongside SI's GPLv3 distribution. The generated app resource `EnglishVocabularyNotices.txt` contains the applicable source notices and pinned revisions. No installed system dictionary is copied.

## Files and offline generation

- [sources.json](../Data/English/sources.json): source IDs, paths, priority, completion scores, provenance and upstream selection.
- [sources.lock.json](../Data/English/sources.lock.json): exact upstream revisions, download/snapshot/license SHA-256 values and import filtering counts.
- [sources/](../Data/English/sources/): checked-in plain UTF-8 snapshots and editable SI lists.
- [overrides.json](../Data/English/overrides.json): lasting exclusions, spelling fixes and preferred capitalization.
- [generated/words.tsv](../Data/English/generated/words.tsv): merged words, contributing sources and completion scores for review.
- [generated/summary.json](../Data/English/generated/summary.json): counts and input/output fingerprints.
- `mac/SI/Core/EnglishLexiconData.swift`: generated data compiled by both the Swift package and Xcode app.

Python 3.9 or later is needed only for maintenance. No additional Python packages are required. Normal app builds use the checked-in generated Swift file without Python, downloads, or a separate runtime vocabulary loader.

On first default-engine construction, the app prepares a shared immutable English Trie and entry metadata from those generated words. Prefix nodes store ranges rather than duplicate word lists; metadata caches word length, casing variants, completion score and mixed continuation cost. Restarting the process rebuilds these derived structures. The source format, completion priorities and deterministic lexical order remain unchanged; no input-result cache or serialized index is added. See [runtime indexing and limits](DICTIONARIES.md).

```sh
./scripts/vocabulary.sh build          # Validate sources and regenerate all outputs, offline
./scripts/vocabulary.sh build --check  # Fail if sources, locks, notices or generated outputs disagree
./scripts/vocabulary.sh stats
./scripts/vocabulary.sh explain subtitle
python3 -m unittest discover -s Tests/VocabularyTests -v
```

The source files contain one word per line. Blank lines and comments beginning with `#` are allowed. Local duplicates, unsupported characters, empty sources, duplicate IDs/priorities, invalid override rules, changed upstream snapshots and license checksum mismatches fail validation. Source priority chooses the canonical casing and completion score for a repeated spelling; all contributing sources remain visible in the merged table. Priority does not select a language or suppress another enabled language.

All English exact matches score 110. Completion scores are explicit editorial values, not corpus frequencies. Existing SI words and terminology retain their earlier score of 85; imported completions score 75 so a much larger word list does not displace established completions in bounded mixed search. Mixed continuation costs reflect the same completion preference. Frequency learning remains separate, opt-in, and unchanged. There is no global cap on direct English candidates.

## Add or correct words

Add a word, with its intended capitalization, to `Data/English/sources/si-terms.txt`. Then regenerate and inspect its provenance:

```sh
./scripts/vocabulary.sh build
./scripts/vocabulary.sh explain subtitle
```

For a word already supplied upstream, use an override instead of editing its snapshot. For example, the following is a synthetic illustration of the supported rules; it is not the current configuration:

```json
{
  "schema_version": 1,
  "rules": [
    {"word": "exampleword", "action": "exclude", "reason": "Incorrect imported entry"},
    {"word": "swfitui", "action": "replace", "replacement": "SwiftUI", "reason": "Correct spelling"},
    {"word": "swiftui", "action": "replace", "replacement": "SwiftUI", "reason": "Preferred capitalization"}
  ]
}
```

Rules match case-insensitively. Replacements can correct spelling or casing and add `si-overrides` to provenance. Rules are applied in file order; exclusions also run last, so an excluded spelling cannot return through a replacement. Use one rule per original spelling and avoid chained replacements. An inactive rule is reported but retained: an upstream removal must not erase our policy if the word is reintroduced later. Removing an override allows upstream data to supply that word again. Personal phrases and learned preferences are not read or changed by these commands.

## Refresh an upstream source

The monthly GitHub Actions workflow audits both English and Chinese; its manual **Run workflow** action also runs an **audit**. They compare tracked upstream branches against pinned revisions, show comparison links and refresh commands in the job summary, and retain a JSON artifact. The workflow uses its read-only GitHub token for API quotas; local public-source checks fall back to Git ref discovery if the API is rate limited. The audit does not execute upstream exporters, change repository contents, open PRs, or update an installed input method. Scheduling begins only after the workflow reaches the default branch and Actions is enabled; it is not a timer installed on this Mac.

```sh
./scripts/vocabulary.sh audit --report .build/vocabulary-upstream-audit.json
# Review the upstream comparison, then use the full commit SHA from the report:
./scripts/vocabulary.sh refresh scowl --revision FULL_40_CHARACTER_COMMIT_SHA
# Explicitly resolve and import the tracked branch's latest commit:
./scripts/vocabulary.sh refresh scowl --latest
# Reproduce the currently pinned import:
./scripts/vocabulary.sh refresh scowl
```

`refresh scowl` downloads a fixed-commit source archive, checks its checksum when reproducing an existing pin, checks the license, and invokes that upstream revision's Python exporter in a temporary directory. It is a maintainer command that executes SCOWL exporter code; review new revisions before importing. The adapter is restricted to `en-wl/wordlist`. Archives reject traversal paths, excessive member counts and excessive unpacked size; only regular files and directories are extracted, and optional links are ignored. Exports run with timeouts. Nothing from this process runs in the input method.

A changed license stops refresh before running the SCOWL exporter. Review the upstream `Copyright` file at the pinned candidate revision and its differences before explicitly supplying `--accept-license-change`. That flag records the new notice; it does not establish that an incompatible license is acceptable. Download, validation and export failures leave existing vocabulary files intact. A result outside the configured word-count bounds fails rather than replacing the vocabulary. Bounds and source-format changes need deliberate review.

After refreshing, review the snapshot, lock, notices, merged table and summary together. Local additions and overrides are reapplied automatically. Run the offline check, maintenance tests, `./scripts/test.sh`, `./scripts/build.sh`, and synthetic benchmarks. Include relevant manual typing checks before release. Commit the source snapshots and generated outputs together through the normal review process; no command commits, publishes, installs, or changes personal data.

## Add another source

For another authored list, add its word file and license notice, then register a distinct ID and priority in `sources.json`. Keep the existing IDs stable for provenance. `completion_score` must be between 0 and 85.

For a reviewed external source, the importer also supports GitHub-hosted plain word lists (`format: wordlist`) and English Rime dictionaries (`format: rime`). Add an `upstream` object with `repository`, `ref`, `format`, `path`, `license_path`, `minimum_words`, `maximum_words`, and optional `minimum_length` (default 2). A Rime import reads the table after the header terminator; explicit codes must match the English word case-insensitively. Chinese entries, shortcut expansions and unsupported spellings are excluded. The source-specific license and its upstream data origins must be reviewed; a repository-wide license alone may not cover every constituent dataset.

After registering a new remote source, inspect its data and license at the intended revision, then initialize its snapshot, notice and lock entry with `./scripts/vocabulary.sh refresh SOURCE_ID --revision FULL_40_CHARACTER_COMMIT_SHA --accept-license-change`. First imports require explicit license acceptance; a source with no snapshot cannot pass offline validation until initialized. Subsequent imports use `refresh`. No tool guesses licenses or automatically adopts new sources. Follow [CONTRIBUTING.md](../CONTRIBUTING.md) when proposing another third-party dataset.
