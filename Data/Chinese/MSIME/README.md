# SI Chinese dictionary

SI maintains this dictionary from pinned MSIME Pinyin sources. The runtime decoder is implemented in Swift. It neither links Rust nor runs MSIME's application, session, learning archive or network services.

`sources.lock.json` identifies the exact engine and dictionary commits, the compressed source snapshots, their original-byte hashes and the reading-correction table. `resources.lock.json` identifies the independently published word-context tables and their source corpus. The application contains no downloader.

`upstream-review.json` records the latest requested upstream review. The default develop branch's Chinese algorithm subtrees and runtime session files have the same Git objects as the retained engine snapshot, and dictionary main still matches the retained sources. This is upstream source identity evidence, not executable validation of SI.

## Maintenance

```sh
# Explicitly adopt source checkouts after reviewing their revisions and notices.
python3 scripts/msime_dictionary.py snapshot --dictionary <msime-dictionary> --engine <msime>

# Rebuild SI's read-only SQLite dictionary from the retained snapshots and SI overlay.
python3 scripts/msime_dictionary.py build
python3 scripts/msime_dictionary.py build --check

# Explicit maintainer-only download of the checksum-pinned context tables.
python3 scripts/msime_dictionary.py fetch-context
```

`build --check` rebuilds offline into a temporary file, checks the packaged SQLite schema, row order, data, indexes and manifest/hash, and checks the pinned context hashes without replacing outputs. `audit --report <path>` reads public upstream commit metadata without adopting updates.

The commands generate files in `mac/SI/Core/Resources/Chinese/`, shared by the Swift package and Xcode app. Resource generation is separate from compiling or running SI.

`si-entries.json` is SI's own maintained overlay. Each entry has `text`, apostrophe-separated `reading`, a documented `reason`, and either an integer `weight` or `exclude: true`. A correction excludes the wrong reading and adds the right one. Keep edits here rather than changing imported snapshots. This public developer-maintained data is separate from each user's private personal phrases and learned preferences.

SI's decoder intentionally lowers the single-character insertion cost relative to upstream; this changes scoring without editing these public dictionary weights or resources. See [current ranking](../../../docs/UNIFIED_RANKING.md).

The importer keeps the larger weight for duplicate text/reading pairs, preserves insertion order for weight ties, applies the pinned reading corrections, then applies the SI overlay. It does not invent pronunciations, retain typed text or read user archives. The generated manifest records the source revisions, overlay hash and shared dictionary format. [English](../../English/SI/README.md) uses the identical SQLite schema, immutable reader and dictionary-relative weight unit from `Data/DictionaryFormat.json`. Empty ASCII-initial buckets and shared metadata do not change Chinese entries, weights or tie order. Character and word weights retain MSIME's Rime Ice / rime-wanxiang provenance; see `NOTICE.md` for the upstream account, including its documented historical provenance limitations.

The word-context tables are MSNG v1 bigram/trigram increments derived by MSIME from the pinned Chinese Wikipedia dump. They are not the experimental KenLM files in `chinese-ime-lm`, and are not a neural model. Their absent entries contribute zero. New SI words can use unigram backoff until context tables are regenerated for the revised vocabulary.

## Attribution

The Swift algorithm adaptation derives from MSIME under GPL-3.0-only. The complete upstream license is `MSIME-GPL-3.0.txt`; SI remains GPLv3. Imported lexical data has per-source terms described in `NOTICE.md` and the pinned upstream lock. Shared Rime Ice / rime-wanxiang entries retain their GPL-3.0 and CC BY 4.0 attribution. The Chinese Wikipedia-derived context artifacts retain CC BY-SA 4.0 attribution and their pinned download/source references in `resources.lock.json`.

## Migration state

The default Chinese path now uses the Swift decoder and these resources. On October 22 the user authorized validation: Debug/Release builds, reproducible resource generation, SQLite integrity and pinned model checksums pass. Full regression checks still fail; no installation or live host check was performed. See `docs/VERIFICATION.md` for the actual scope. Quality parity with MSIME is not established. Fixed spelling aliases, initial splitting and sparse lookup fallbacks are written with source-boundary mapping. General optional typo paths, optional neural reranking, and an independent comparison remain tracked in `docs/IMPLEMENTATION_PLAN.md`. This is SI's sole maintained Chinese dictionary. Legacy Chinese data has been removed; English spellings and functionality are retained through the shared SI SQLite/weight contract and its own public overlay. Private personal phrases and learning archives are unchanged. Bounded complete-Pinyin/English lexical paths now use the same maintained dictionaries; mixed initials and incomplete Chinese-tail prediction remain limited. See [the algorithm study](../../../docs/MSIME_ALGORITHM.md) for the pinned source references and the distinction between dictionary weights and sentence scoring.
