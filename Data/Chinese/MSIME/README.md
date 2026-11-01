# SI Chinese decoder/context and historical dictionary sources

The App uses dictionary, spelling and language-transition costs without corpus context.
The two original MSNG binaries are preserved byte-for-byte under `artifacts/`,
with the same lock and attribution; they are no longer App resources or runtime
ranking inputs. The compatibility fetch/check commands below target that archive.

SI retains the pinned MSIME decoder adaptation and Chinese word-context artifacts. The current Chinese and English bases now come from [Wanxiang](../../Vocabulary/Wanxiang/README.md), with separate upstream categories; the preexisting SI categories retain their historical MSIME-derived entries. The runtime decoder is implemented in Swift. It neither links Rust nor runs MSIME's application, session, learning archive or network services.

The Chinese source record in `Data/Vocabulary/meta.json` preserves the exact engine/dictionary commits, original source-byte hashes and the applied reading-correction hash. The old compressed wordlists and correction table have been deleted after migration. `resources.lock.json` identifies the independently published word-context tables and their source corpus. The application contains no downloader.

`upstream-review.json` records the latest requested upstream review. The default develop branch's Chinese algorithm subtrees and runtime session files have the same Git objects as the retained engine snapshot, and dictionary main still matches the retained sources. This is upstream source identity evidence, not executable validation of SI.

## Vocabulary maintenance

The editable Chinese vocabulary now lives in [Data/Vocabulary/chinese](../../Vocabulary/chinese/README.md), grouped into base plus eight domain CSVs. Common and unclassified rows remain in base; further categories can be added in the same directory. The [CSV workflow](../../Vocabulary/README.md) replaces upstream snapshot adoption and the public JSON overlay. The historical October 27 migration preserved 953,625 entries after deduplication, reading corrections and private-use exclusions. The October 29 Wanxiang base replacement supersedes those base entries/weights, while preserving the nonbase CSVs. Ordinary Han extension characters remain available. CSV rows now have only text/reading/weight; the compiler merges overlaps using maximum weight and generates tie order from content.

Bootstrap source metadata is now inline in [meta.json](../../Vocabulary/meta.json). This directory retains licenses, notices, the algorithm-review records and the independent context lock, without old lexical data. Ordinary builds compile only the maintained CSVs; explicit Wanxiang imports use the separate locked converter. The old JSON overlay is retired. No snapshot adoption command overwrites the CSV collection. Attribution remains applicable to the migrated data.

```sh
python3 scripts/csv_dictionary.py build
python3 scripts/csv_dictionary.py build --check
# Compatibility command: Chinese CSV check plus pinned context verification.
python3 scripts/msime_dictionary.py build --check
# Explicit maintainer-only download of pinned context tables.
python3 scripts/msime_dictionary.py fetch-context
```

`audit --report <path>` still compares the historical upstream commits without adopting changes. SQLite output remains shared by package and app. SI's two-nat character cost differs from upstream without rescaling stored weights; see [ranking](../../../docs/UNIFIED_RANKING.md).

The word-context tables are MSNG v1 bigram/trigram increments derived by MSIME from the pinned Chinese Wikipedia dump. They are not a neural model and do not participate in runtime scoring. Absent entries contribute zero in historical format fixtures; changing the runtime vocabulary does not regenerate these archived tables.

## Attribution

The Swift algorithm adaptation derives from MSIME under GPL-3.0-only. The complete upstream license is `MSIME-GPL-3.0.txt`; SI remains GPLv3. Imported lexical data has per-source terms described in `NOTICE.md` and the pinned upstream lock. Shared Rime Ice / rime-wanxiang entries retain their GPL-3.0 and CC BY 4.0 attribution. The Chinese Wikipedia-derived context artifacts retain CC BY-SA 4.0 attribution and their pinned download/source references in `resources.lock.json`.

## Migration state

The default Chinese path now uses the Swift decoder and these resources. On October 22 the user authorized validation: Debug/Release builds, reproducible resource generation, SQLite integrity and pinned model checksums pass. Full regression checks still fail; no installation or live host check was performed. See `docs/VERIFICATION.md` for the actual scope. Quality parity with MSIME is not established. Fixed spelling aliases, initial splitting and sparse lookup fallbacks are written with source-boundary mapping. General optional typo paths, optional neural reranking, and an independent comparison remain tracked in `docs/IMPLEMENTATION_PLAN.md`. Both sources compile into SI's single shared Chinese runtime dictionary. Legacy Chinese data has been removed; English spellings and functionality are retained through the shared SI SQLite/weight contract and its own maintained CSV categories. Private personal phrases and learning archives are unchanged. Bounded complete-Pinyin/English lexical paths now use the same maintained dictionaries; mixed initials and incomplete Chinese-tail prediction remain limited. See [the algorithm study](../../../docs/MSIME_ALGORITHM.md) for the pinned source references and the distinction between dictionary weights and sentence scoring.
