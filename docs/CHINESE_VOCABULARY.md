# Chinese vocabulary maintenance

The current [base.csv](../Data/Vocabulary/chinese/base.csv) is converted from pinned Wanxiang `zi.dict.yaml`, `jichu.dict.yaml` and `duoyin.dict.yaml`. The original import contains 1,547,554 text/toneless-reading pairs; the maintained word-side base now contains 1,501,057 after the [phrase split](../Data/Vocabulary/chinese/phrase/README.md), initially preserving upstream integer weights, with [documented SI editorial adjustments](../Data/Vocabulary/chinese/README.md#si-editorial-weight-adjustments). Tone marks are removed from readings, ü becomes `v`, and tone-collapsed duplicate identities retain the maximum source weight. Output text is not normalized. The [import guide](../Data/Vocabulary/Wanxiang/README.md) contains the source lock, CC BY 4.0 data licensing, exact transformations and reproduction/update workflow.

The seven remaining local nonbase category CSVs retain their text/readings with all weights set to 10. Base owns overlapping weights, including lower or zero weights; categories add missing identities, with maximum-weight merging among nonbase duplicates. Existing movie/domain catalogs and source attribution remain intact. The requested `炼仙丹` now exists in the Wanxiang base with source weight 333, replacing the former SI-authored base weight of 2,916.

Ten other normal upstream dictionaries remain separate categories named after the upstream files, containing 602,516 rows; see the import guide for names and per-file counts. Their weights take precedence over legacy category copies absent from base. With the separate corpus additions, the merged Chinese database has 2,141,468 entries.

The [HanLP corpus review](../Data/Vocabulary/Corpus/README.md) adds 266 reviewed
terms in [corpus.csv](../Data/Vocabulary/chinese/corpus.csv) and makes eight
bounded authoritative base-weight corrections. Its accepted table retains
per-source counts and explicit readings; all eligible exclusions and old/new
weights are separately reviewable. New corpus-category weights are explicit
editorial values anchored to existing word weights, capped at 5,000, rather
than raw counts or the default local 10. Other category weights and prior user
adjustments remain intact. HanLP stays an offline analysis tool; no model or
Python dependency is added to the app. See the review for source limits,
attribution, independent recount commands and upstream-refresh precautions.

The old MSIME-derived base is replaced. Historical source records and licenses remain for retained category data and attribution. The shared runtime contract is `si-wanxiang-weight-v1`, reference mass one and unknown weight one; no wordfreq conversion or frequency rescaling is applied. These are source ranking weights, not measured occurrence counts or normalized probabilities.

```sh
python3 scripts/wanxiang_dictionary.py fetch
python3 scripts/wanxiang_dictionary.py convert
python3 scripts/wanxiang_dictionary.py convert --check
python3 scripts/csv_dictionary.py build
python3 scripts/csv_dictionary.py build --check
python3 scripts/msime_dictionary.py build --check
python3 -m unittest discover -s Tests/VocabularyTests -v
./scripts/test.sh
./scripts/build.sh
```

Only `fetch` downloads source data. Conversion replaces both bases and imported categories offline; normal CSV builds do not reimport them. Reimport overwrites manual base edits; keep additional SI vocabulary in separate categories. See [the CSV contract](../Data/Vocabulary/README.md) for editing and duplicate precedence.

The preserved local categories came from an earlier broad heuristic grouping of the MSIME-derived collection. That grouping was not exhaustive semantic annotation and does not classify the current Wanxiang base. New upstream classifications remain separate; no automatic semantic classifier runs during builds. Base owns overlaps, imported Wanxiang categories take precedence over legacy copies absent from base, and duplicates within each tier use maximum weight. New category files are discovered automatically without provider registration or Settings changes. Chinese sources also include flat CSVs in `Data/Vocabulary/chinese/phrase/`; original basenames preserve their base/upstream tier across the two directories. Output text remains byte-preserving and row IDs follow content order.

See [the CSV contract and category workflow](../Data/Vocabulary/README.md) for columns, validation, ties, weights and provenance. [English](ENGLISH_VOCABULARY.md) uses the same compiler and SQLite schema. Source-level provenance is indexed once in [meta.json](../Data/Vocabulary/meta.json); source versions and input hashes are inline there, while full licenses and attribution remain under [Data/Chinese/MSIME](../Data/Chinese/MSIME/README.md). MSIME's underlying Rime Ice / rime-wanxiang attribution still applies. Moving data into SI CSV does not erase those obligations.

```sh
python3 scripts/csv_dictionary.py build
python3 scripts/csv_dictionary.py build --check
python3 scripts/msime_dictionary.py build --check
python3 -m unittest discover -s Tests/VocabularyTests -v
./scripts/test.sh
./scripts/build.sh
```

The first two commands compile/check both languages offline. The Chinese compatibility command compiles the Chinese CSV collection and also verifies the pinned context-table sizes/hashes. Runtime SQLite files contain data and lookup indexes, not references back into CSV. App and package share the same resources; no import or download occurs while typing.

Historical word-context tables, archived outside App resources under `Data/Chinese/MSIME/artifacts/`, are independently pinned in `Data/Chinese/MSIME/resources.lock.json`. They are not regenerated when words change and are not loaded by the App. Runtime scoring uses dictionary, spelling and language-transition costs. Fetching these existing pinned tables remains an explicit maintainer action:

```sh
python3 scripts/msime_dictionary.py fetch-context
```

`python3 scripts/msime_dictionary.py audit --report .build/vocabulary-msime-audit.json` reads the recorded MSIME revisions from `meta.json` and compares them with upstream without adopting changes. Any upstream update must be reviewed, licensed and deliberately integrated into the maintained CSVs. This audit does not adopt lexical updates. Wanxiang adoption uses its separate explicit fetch/convert workflow; context adoption remains separate.

Private phrases and opt-in app vocabulary retain their own consent, retention and deletion controls. These maintenance commands never read user archives. Automated resource checks do not establish input quality or native host compatibility; see [testing](TESTING.md).
