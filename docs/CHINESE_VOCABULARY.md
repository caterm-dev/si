# Chinese dictionary maintenance

SI maintains one Chinese dictionary family: the [MSIME-derived sources](../Data/Chinese/MSIME/README.md). The former direct Rime Chinese selection and original SI tables have been removed. [English maintenance](ENGLISH_VOCABULARY.md) now uses the same weighted-snapshot, SI-overlay and SQLite contract. Both share the schema and fixed dictionary-relative weight unit defined in `Data/DictionaryFormat.json`; Chinese entries and numerical weights are unchanged. MSIME's own upstream Rime Ice / rime-wanxiang attribution remains required; using one maintained source does not erase its underlying provenance.

## Source and runtime files

| Path | Role |
| --- | --- |
| `Data/Chinese/MSIME/sources/*.gz` | Byte-preserving compressed snapshots of the five pinned MSIME lexical inputs |
| `Data/Chinese/MSIME/sources.lock.json` | Engine/dictionary revisions, source sizes and checksums |
| `Data/Chinese/MSIME/reading-corrections.tsv` | Pinned upstream reading corrections |
| `Data/Chinese/MSIME/si-entries.json` | SI-maintained public additions, exclusions and weight corrections |
| `mac/SI/Core/Resources/Chinese/si-pinyin.sqlite` | Generated runtime words, explicit readings, weights, initials and lookup indexes |
| `mac/SI/Core/Resources/Chinese/dictionary-manifest.json` | Build provenance, count and generated database checksum |
| `Data/Chinese/MSIME/resources.lock.json` | Independently pinned MSIME word-context artifacts and corpus attribution |

The SQLite file is a compiled dictionary containing both data and indexes. It is not the editable source or an index pointing back into source text files. App and package use the same read-only database; no source parsing, regeneration or downloads occur on a keystroke.

The retained inputs produce 953,710 unique text/reading entries with an empty SI overlay. Different explicit pronunciations remain distinct. This count is not a quality or coverage measure. MSIME bigram/trigram tables remain part of the same dictionary family; they supply context scores rather than replacement word lists.

## Make a public correction

Edit `Data/Chinese/MSIME/si-entries.json`, then rebuild. Each entry requires nonempty `text`, apostrophe-separated lowercase `reading`, a `reason`, and either a nonnegative signed-64-bit integer `weight` or `exclude: true`. Duplicate text/reading pairs, unsupported fields, control characters and conflicting weight/exclusion fields are rejected.

Synthetic format examples, not proposed dictionary changes:

```json
[
  {"text": "示例", "reading": "shi'li", "weight": 100, "reason": "Synthetic format example"},
  {"text": "示例", "reading": "shi'lie", "exclude": true, "reason": "Synthetic wrong-reading exclusion"}
]
```

The builder imports checksum-verified snapshots, merges duplicate text/readings using upstream weight/row-order policy, applies pinned reading corrections, then applies the SI overlay. It stores the resulting data and key/initial indexes. Do not edit the SQLite file or imported snapshots to make lasting local corrections. Weights are model inputs, not measured probabilities or guaranteed candidate positions.

## Build and check

Run from the repository root:

```sh
python3 scripts/msime_dictionary.py build
python3 scripts/msime_dictionary.py build --check
python3 scripts/english_dictionary.py build --check
python3 scripts/ranking.py --check
python3 -m unittest discover -s Tests/VocabularyTests -v
./scripts/test.sh
./scripts/build.sh
```

`build` works offline from retained sources. `build --check` rebuilds into a temporary file, checks schema, row order, data, indexes and the retained database hash/manifest, verifies context sizes/hashes, and leaves packaged outputs unchanged. Equivalent databases from another SQLite version are accepted even when header or page bytes differ; source/overlay checks and retained binary hashes must still agree. A source or overlay error must not replace the existing dictionary. The Python fixtures check ties, duplicate merging, overlay exclusions/additions, invalid edits, reproducibility and preservation on failure. Full core/quality failures remain visible; removing old data does not establish MSIME conversion parity.

## Adopt upstream changes

Review the new revisions, data changes and notices first. Snapshot adoption is explicit:

```sh
python3 scripts/msime_dictionary.py snapshot --dictionary /path/to/msime-dictionary --engine /path/to/msime
python3 scripts/msime_dictionary.py build
python3 scripts/msime_dictionary.py build --check
# Only when the pinned context artifacts are intentionally needed:
python3 scripts/msime_dictionary.py fetch-context
```

Review `sources.lock.json`, the independently retained upstream/license/review records and generated manifest together when adopting revisions. Context releases have a separate pin; updating lexical sources does not automatically regenerate or upgrade context tables. New words use unigram backoff where context entries are absent. Keep all required notices with distributed data; see [the retained attribution](../Data/Chinese/MSIME/README.md#attribution) and [CONTRIBUTING.md](../CONTRIBUTING.md).

The existing monthly audit checks MSIME engine/dictionary revision metadata, retained-file consistency and the preserved English sources. `python3 scripts/msime_dictionary.py audit --report .build/vocabulary-msime-audit.json` produces a read-only comparison report; neither audit nor CI adopts updates automatically. The schedule takes effect only after the workflow reaches the default branch with Actions enabled.

Private personal phrases and opt-in aggregate learning remain separate, with their existing retention/deletion controls. Maintenance tools never inspect those archives.
