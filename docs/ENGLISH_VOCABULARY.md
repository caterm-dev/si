# English vocabulary maintenance

SI maintains English using the same contract as [Chinese](CHINESE_VOCABULARY.md): pinned weighted source snapshots, an SI-owned public overlay, and a generated read-only SQLite database. Both languages share database schema, integer weight unit and runtime reader. Source attribution remains language-specific; these are not input modes or Settings toggles.

## Daily SI maintenance

The maintained runtime source lives in [Data/English/SI](../Data/English/SI/README.md). Edit `Data/English/SI/si-entries.json` for additions, exclusions, spelling/casing corrections and weight adjustments. It has the same `text`, `reading`, `weight`/`exclude`, and `reason` fields as Chinese. English readings are the exact lowercase form of 1–64 ASCII letters. A casing/spelling correction excludes the old identity and adds its replacement. Public edits never touch private phrases or learning archives.

```sh
python3 scripts/english_dictionary.py build
python3 scripts/english_dictionary.py build --check
```

The result is `mac/SI/Core/Resources/English/si-english.sqlite`, plus a provenance/count/checksum manifest. The app and package use this same resource. No generated English word/frequency Swift arrays remain. Builds validate the retained weighted snapshot and notices, apply SI edits, and preserve existing outputs on invalid input. Ordinary builds do not reimport upstream sources or recalculate weights.

To inspect weights without a database viewer, open [Data/English/SI/generated/weights.tsv](../Data/English/SI/generated/weights.tsv). Builds regenerate this text table from the final database, including public SI edits, sorted by descending weight; `--check` verifies it is current. Search for a word in a text editor. The columns are text, lowercase reading and integer weight. To change a value, edit the public overlay and rebuild; the TSV is a generated view. Weight is a base-frequency input, not the complete candidate score.

`Data/DictionaryFormat.json` defines the common unit: one relative-frequency point in a fixed reference mass of 7,694,577,936. This is the initial retained Chinese text/reading weight sum; Chinese numeric weights remain unchanged. The initial English import normalizes wordfreq frequency across retained words plus an unknown floor, multiplies by this mass, and rounds to an integer of at least one. The conversion and unknown weight are pinned in `sources.lock.json`. Both languages' overlay weights use these same points, including zero with a one-point computational scoring floor. Never rescale stored weights merely because an entry is added or deleted. These are comparable dictionary-relative priors, not observations from a common corpus or calibrated complete-candidate scores.

The remaining sections describe the retained materials used to bootstrap or explicitly refresh the weighted base snapshot. Editing those import materials alone does not change the runtime database. After reviewing and regenerating them, use `python3 scripts/english_dictionary.py snapshot` to adopt a new base, then `build`; the public SI overlay is preserved and reapplied. See [the complete workflow and attribution](../Data/English/SI/README.md).

## Current sources

| Source | Purpose | Pinned words | Legacy completion metadata |
| --- | --- | ---: | ---: |
| `scowl` | ESDB/SCOWL medium-size American English selection | 61,172 | 75 |
| `si-original` | All words from SI's original English vocabulary | 638 | 85 |
| `si-terms` | SI-maintained terminology and explicit coverage additions | 22 | 85 |
| `cspell-tools` | CSpell software tools, products and services | 572 | 75 |
| `cspell-companies` | CSpell company and organization names | 718 | 75 |
| `rime-ice-english` | Rime Ice English extension names and abbreviations | 1,447 | 75 |

The merged result contains **63,602** case-insensitively unique words, including `subtitle`, `Gmail`, `GitHub`, `OpenAI`, `ChatGPT`, and `WeChat`. The three technology sources add 2,386 unique spellings to the earlier 61,216-word vocabulary. These are word forms, not headwords or a measured coverage score. Run `./scripts/vocabulary.sh stats` for current counts. Importing more words does not establish production ranking, correction, or host compatibility.

The initial SCOWL commit is `1e5b7d3a72f47a71da5d28686c1dd4b397178485`. The export selects size 50, American spelling `A`, variant level 1, the default category and POS class, and excludes abbreviations. SCOWL's POS classifications are incomplete, so this selection can still contain proper names and uncommon words. Only ASCII alphabetic forms of 2–64 letters are imported. Apostrophes, spaces, hyphens, accents, numbers, and standalone letter names are filtered rather than rewritten. SI's original `a` and `I` remain available. No diacritics are stripped and no text is silently transliterated.

`si-original` and `si-terms` are original SI data under GPLv3. The full upstream SCOWL copyright notice is retained in [the license directory](../Data/English/licenses/SCOWL.txt). SCOWL explicitly permits use, modification and redistribution of generated word lists while preserving its notices. Keep those permissive notices alongside SI's GPLv3 distribution. The generated app resource `EnglishVocabularyNotices.txt` contains the applicable source notices and pinned revisions. No installed system dictionary is copied.

## Technology sources and selection

CSpell is pinned to `5f051955183427037faba538a3e102a94951d003`; Rime Ice English is pinned independently to `da1fbe602e38f26db846fa10120ee64c2b0324c0`:

- [CSpell software tools](https://github.com/streetsidesoftware/cspell-dicts/blob/5f051955183427037faba538a3e102a94951d003/dictionaries/software-terms/src/software-tools.txt) supplies products, tools and services, including upstream `GMail`.
- [CSpell companies](https://github.com/streetsidesoftware/cspell-dicts/blob/5f051955183427037faba538a3e102a94951d003/dictionaries/companies/src/companies.txt) supplies company and organization names. It also contains non-technology names and stock symbols; accepted entries are not a curated list of popular technology products.
- [Rime Ice English extension](https://github.com/iDvel/rime-ice/blob/da1fbe602e38f26db846fa10120ee64c2b0324c0/en_dicts/en_ext.dict.yaml) supplies names and abbreviations from `en_ext`. The pinned README describes this as its maintained internet/abbreviation extension and declares GPL-3.0-only. This import uses that extension file, with its explicit output/code pairs, rather than Rime's other English dictionaries.

CSpell package-specific MIT notices are retained in [CSpellSoftwareTerms-MIT.txt](../Data/English/licenses/CSpellSoftwareTerms-MIT.txt) and [CSpellCompanies-MIT.txt](../Data/English/licenses/CSpellCompanies-MIT.txt). The Rime Ice GPLv3 notice is retained in [RimeIce-GPL-3.0.txt](../Data/English/licenses/RimeIce-GPL-3.0.txt). Their copyright/license texts are included in the generated app notices. These data files are processed during maintenance; no CSpell or Rime runtime dependency is added.

All three imports retain only ASCII alphabetic spellings of 2–64 letters. CSpell's `cspell` adapter removes whitespace-delimited inline comments, including tab-before-comment annotations; other tabs, compound markers, numbers, punctuation, spaces and accented forms are rejected as complete rows. For example, `C#` is rejected rather than reduced to `C`. Rime rows must have matching word/code spellings, ignoring case; shortcut expansions, multiword outputs and upstream weights are excluded. Filtering and case-collapse counts are recorded in the lock. Multiword company names are not split into unrelated tokens, and unsupported forms remain available as exact literal input where composition permits them.

Source priority chooses casing and completion score for duplicates: `cspell-companies` (1), `cspell-tools` (2), `rime-ice-english` (3), SCOWL (10), SI original (100), SI terminology (200), then explicit overrides. All 61,216 pre-existing spellings retain their prior casing and completion score at this import. This preserves ordinary `may`, `can` and `will` while adding previously absent names. The durable `gmail` override changes upstream `GMail` to `Gmail`. Contributions from every source remain traceable with `explain`.

The 75/85 source fields remain legacy import provenance metadata and do not affect runtime ranking. These lists provide spellings; wordfreq 3.1.1 supplies the initial base weights only during explicit snapshot adoption. Added words and abbreviations can change mixed segmentation, ranking and bounded unknown-span choices. For example, `QWERT` becomes a known prefix; privacy fixtures therefore use a synthetic span without that lexical prefix and check unknown text after a known product. Any generated path still containing an unrecognized span remains excluded from learning/context, and the complete exact input remains independently available.

The manual `./scripts/vocabulary.sh audit` command includes these registered sources automatically. Reproduce the pinned imports with:

```sh
./scripts/vocabulary.sh refresh cspell-tools
./scripts/vocabulary.sh refresh cspell-companies
./scripts/vocabulary.sh refresh rime-ice-english
./scripts/vocabulary.sh explain gmail
```

Use the existing review/refresh workflow for updates; source-specific license changes still stop an unapproved refresh. The English Rime pin is independent of the Chinese sources so updates can be reviewed separately.

## Import files and offline preparation

- [sources.json](../Data/English/sources.json) and [sources.lock.json](../Data/English/sources.lock.json): import IDs, priorities, provenance, pinned versions, filtering and checksums.
- [sources/](../Data/English/sources/), [overrides.json](../Data/English/overrides.json) and [licenses/](../Data/English/licenses/): retained spelling imports, import-time overrides and notices.
- [generated/words.tsv](../Data/English/generated/words.tsv) and [generated/summary.json](../Data/English/generated/summary.json): reviewable import output and fingerprints.
- [SI/sources/](../Data/English/SI/sources/), [SI/sources.lock.json](../Data/English/SI/sources.lock.json) and [SI/si-entries.json](../Data/English/SI/si-entries.json): maintained weighted snapshot, provenance and daily public edits.
- `mac/SI/Core/Resources/English/`: generated runtime database and manifest, sharing the Chinese schema and unit.

Python 3.9+ and its standard library are needed only for maintenance. Normal app builds use the retained SQLite resource without Python or downloads. On the first English query, a candidate worker loads its database rows and constructs the shared immutable trie, metadata and top-eight provisional cache once. Direct lookup and English-only segmentation use that same vocabulary; no database file access is added to each keystroke. Missing or incompatible resources fail closed while exact literal fallback remains available.

```sh
./scripts/vocabulary.sh build          # Prepare/review retained spelling imports, offline
./scripts/vocabulary.sh build --check
python3 scripts/ranking.py             # Prepare retained attribution and synthetic calibration
python3 scripts/ranking.py --check
# Explicitly adopt prepared imports only after reviewing changes:
python3 scripts/english_dictionary.py snapshot
python3 scripts/english_dictionary.py build
python3 scripts/english_dictionary.py build --check
python3 -m unittest discover -s Tests/VocabularyTests -v
```

Snapshot adoption reads the pinned wordfreq 3.1.1 English cBpack and notices in `Data/Ranking/wordfreq-3.1.1/`. Missing words use its documented frequency floor. Derived weighted data retains CC-BY-SA-4.0 attribution. Ordinary dictionary builds read only the adopted weighted snapshot and public overlay. Runtime adds no Python dependency or networking. Direct English lookup retains all matching candidates; bounded sentence/completion search does not establish broad coverage or mixed-language quality.

## Prepare import-level changes

Use `Data/English/SI/si-entries.json` for daily SI dictionary maintenance. To intentionally update the original import materials instead, add a spelling to `Data/English/sources/si-terms.txt`, run `./scripts/vocabulary.sh build`, and inspect it with `./scripts/vocabulary.sh explain WORD`. Only explicit `snapshot` adoption initializes its base weight and makes the import available to the runtime builder.

For an import-level correction to a word already supplied upstream, use an import override instead of editing its pinned snapshot. For example, the following is a synthetic illustration of the supported rules; it is not the current configuration:

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

Run `./scripts/vocabulary.sh audit --report .build/vocabulary-english-audit.json` manually to compare tracked upstream branches against pinned revisions and save a JSON report. Check Chinese sources separately with `python3 scripts/msime_dictionary.py audit --report .build/vocabulary-msime-audit.json`. Public-source checks fall back to Git ref discovery if the API is rate limited. Audits do not execute upstream exporters, change repository contents, open PRs, or update an installed input method. No scheduled vocabulary workflow remains.

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

After refreshing, review the import snapshot, lock, notices, merged table and summary together. Regenerate notices with `python3 scripts/ranking.py`, explicitly adopt the reviewed base with `python3 scripts/english_dictionary.py snapshot`, and build/check the runtime database. SI overlay entries continue to win. Local additions and overrides are reapplied automatically. Run the offline check, maintenance tests, `./scripts/test.sh`, `./scripts/build.sh`, and synthetic benchmarks. Include relevant manual typing checks before release. Commit the source snapshots and generated outputs together through the normal review process; no command commits, publishes, installs, or changes personal data.

## Add another source

For another authored list, add its word file and license notice, then register a distinct ID and priority in `sources.json`. Keep the existing IDs stable for provenance. `completion_score` must be between 0 and 85.

For a reviewed external source, the importer also supports GitHub-hosted plain word lists (`format: wordlist`), annotated CSpell source lists (`format: cspell`), and English Rime dictionaries (`format: rime`). Add an `upstream` object with `repository`, `ref`, `format`, `path`, `license_path`, `minimum_words`, `maximum_words`, and optional `minimum_length` (default 2). A Rime import reads the table after the header terminator; explicit codes must match the English word case-insensitively. Chinese entries, shortcut expansions and unsupported spellings are excluded. The source-specific license and its upstream data origins must be reviewed; a repository-wide license alone may not cover every constituent dataset.

After registering a new remote source, inspect its data and license at the intended revision, then initialize its snapshot, notice and lock entry with `./scripts/vocabulary.sh refresh SOURCE_ID --revision FULL_40_CHARACTER_COMMIT_SHA --accept-license-change`. First imports require explicit license acceptance; a source with no snapshot cannot pass offline validation until initialized. Subsequent imports use `refresh`. No tool guesses licenses or automatically adopts new sources. Follow [CONTRIBUTING.md](../CONTRIBUTING.md) when proposing another third-party dataset.
