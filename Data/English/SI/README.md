# SI English dictionary

SI maintains this dictionary using the same source/overlay/database contract as [Chinese](../../Chinese/MSIME/README.md). Normal maintenance is local and offline. It does not reimport upstream lists or recalculate existing weights.

| Path | Role |
| --- | --- |
| `sources/english-base.txt.gz` | Pinned UTF-8 `text`, lowercase `reading`, integer `weight` rows |
| `sources.lock.json` | Snapshot size/hash, bootstrap provenance, notices and weight conversion |
| `si-entries.json` | SI-owned public additions, exclusions and weight corrections |
| [generated/weights.tsv](generated/weights.tsv) | Readable effective words/readings/weights, sorted by descending weight |
| `../../../mac/SI/Core/Resources/English/si-english.sqlite` | Generated read-only runtime dictionary |
| `../../../mac/SI/Core/Resources/English/dictionary-manifest.json` | Source/overlay/format fingerprints, count and runtime checksum |

The initial snapshot contains 63,602 unique ASCII word forms. It preserves all canonical spellings from the retained SCOWL/CSpell/Rime/SI imports. Wordfreq 3.1.1 supplies the initial relative frequencies; it is not consulted during ordinary dictionary builds or typing. The original import files, pins and full licenses remain under `Data/English/` and `Data/Ranking/wordfreq-3.1.1/`. [English maintenance](../../../docs/ENGLISH_VOCABULARY.md) documents those sources and how to deliberately adopt an updated import.

Open [generated/weights.tsv](generated/weights.tsv) in a text editor to inspect or search the weights without a SQLite viewer. Its columns are `text`, `reading`, and `weight`; higher weights mean stronger base frequency. Each build regenerates this view from the effective database after public SI edits, and `build --check` rejects a stale view. Edit `si-entries.json` to change weights, then rebuild; editing the generated TSV does not change the dictionary. Candidate order also depends on completion, segmentation, context and learning.

## Public maintenance

Edit `si-entries.json` using exactly the Chinese overlay fields. Synthetic examples:

```json
[
  {"text": "ExampleTool", "reading": "exampletool", "weight": 100, "reason": "Synthetic addition"},
  {"text": "obsoleteexample", "reading": "obsoleteexample", "exclude": true, "reason": "Synthetic exclusion"}
]
```

English text must contain 1–64 ASCII letters and its reading must be its exact lowercase spelling. For a weight correction, specify the existing text/reading identity and a replacement weight. To correct casing or spelling, exclude the old identity and add the replacement. Readings remain case-insensitively unique. Duplicate/conflicting edits, Boolean or out-of-range weights and unsupported spellings fail before replacing a database. Personal phrases and learned preferences remain separate and are never read by maintenance tools.

```sh
python3 scripts/english_dictionary.py build
python3 scripts/english_dictionary.py build --check
```

`build` verifies the compressed snapshot and retained notices, applies the overlay, and generates the database and manifest. `--check` rebuilds into a temporary file and compares schema, metadata, ordered data, indexes and integrity without replacing outputs. Equivalent SQLite page layouts are accepted only when the retained manifest/hash also agrees. Invalid inputs preserve the existing output.

## Shared format and weight unit

[Data/DictionaryFormat.json](../../DictionaryFormat.json) defines the shared version and unit. Both databases have identical bucket tables (`key`, `jp`, `value`, integer `weight`), lookup indexes and a `dictionary_metadata` table. Chinese keys separate syllables with apostrophes; an English word is one lookup unit. Empty buckets are retained so schema is identical for both languages. Both use the same immutable SQLite reader; English builds its existing in-memory trie once on a candidate worker.

One weight point is one share of the fixed **7,694,577,936** reference mass: the sum of the retained Chinese text/reading weights before public overlays at this migration. Chinese stored weights stay unchanged. Initial English weights are `max(1, round(p × reference_mass))`, where `p` is wordfreq frequency normalized over the retained English vocabulary plus its unknown floor. The snapshot lock records the normalization mass and the rounded unknown weight. The reference mass stays fixed when either dictionary changes; adding a word must not rescale every existing entry.

This is a shared dictionary-relative frequency unit, not a claim that the two sources observed the same corpus or that complete candidate scores are calibrated probabilities. Chinese insertion/context costs and English spelling/segmentation costs remain distinct. The bounded mixed lexical decoder now uses these shared points for Chinese and English word edges; full candidate placement remains an explicit policy. Mixed initials and incomplete Chinese-tail prediction remain limited. A weight of zero is retained; scoring uses a one-point computational floor.

## Explicitly adopt retained imports

Only after reviewing changes to the original import files, pins and notices:

```sh
./scripts/vocabulary.sh build
python3 scripts/ranking.py
python3 scripts/english_dictionary.py snapshot
python3 scripts/english_dictionary.py build
```

`snapshot` is an explicit offline adoption command. It replaces the base snapshot/lock from the reviewed imports and reinitializes base weights in the common unit; the SI overlay remains intact and wins on the next build. Ordinary `build` does not call it. Review snapshots, provenance, licenses and generated outputs together. Keep the SCOWL and CSpell notices, Rime/SI GPLv3 terms, and wordfreq CC-BY-SA-4.0 attribution with distributions. No new third-party data source or runtime dependency is introduced.
