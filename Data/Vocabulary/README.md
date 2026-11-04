# SI-maintained vocabulary

These CSV files are the editable source of both runtime dictionaries. A pinned Wanxiang conversion supplies the two base files: 1,547,554 Chinese text/toneless-reading pairs from `zi`, `jichu` and `duoyin`, and 72,784 supported English forms from `en`. Ten other normal Chinese source dictionaries retain separate categories named after the upstream files (602,516 rows). The merged resources contain 2,141,202 Chinese and 74,341 English entries. See [the source lock, conversion rules and update workflow](Wanxiang/README.md).

The existing Chinese geography, organizations, technology, science, medicine, movie and game category files, and English movie/domain files, keep their text/readings; all their weights are now 10. Base identities own their upstream weights and English casing; imported Wanxiang categories then take precedence over legacy copies, with other category identities retained as supplements. Category names do not create input-language modes, Settings switches or ranking bonuses. Retained [domains](DOMAINS.md) and [movies](MOVIES.md) keep their own provenance and data terms.

The SI-authored [English technology category](english/technology.csv) adds a maintenance group of 164 common terms, including `AI`, `LLM`, `API`, `GPU` and `Core ML`, at editorial weight 10. Overlapping base entries retain their weights and casing. See [technology maintenance](../../docs/ENGLISH_VOCABULARY.md#technology-category).

`meta.json` records current source pins and historical bootstrap attribution outside the rows. The new source and conversion report are under `Wanxiang/`; old MSIME, SCOWL, CSpell, Rime Ice and wordfreq records remain historical notices for retained category data and provenance. Normal compilation uses CSV only, without a download or upstream conversion.

The SI-authored [common English additions](english/common.csv) restore the article `a` at the default editorial weight 10, independently of upstream base conversion. See [common-word maintenance](../../docs/ENGLISH_VOCABULARY.md#common-english-additions).

## CSV contract

UTF-8 CSV, with this exact header:

```csv
text,reading,weight
```

- `text`: exact committed bytes, preserving capitalization and Unicode. Nonempty, no control characters, at most 4,096 UTF-8 bytes.
- `reading`: explicit lowercase reading. Chinese syllables use apostrophes, such as `ni'hao`. English word/title keys contain 1–64 lowercase ASCII letters: lowercase the output's letters, omit spaces/punctuation, and spell Arabic digits individually (`2` → `two`, `2049` → `twozerofournine`). Plain words keep their exact lowercase reading. English outputs may contain printable ASCII spaces, punctuation and digits, with at least one letter and no leading/trailing spaces; accented forms remain unsupported. Full domain names use their exact lowercase ASCII text as the reading, including dots, hyphens and digits (`google.com` → `google.com`), up to 253 characters with labels of at most 63. Domain category rows require identical text/reading and exclude standalone suffixes; see the [domain contract](DOMAINS.md#editing-and-typing).
- `weight`: integer from 0 through 9,223,372,036,854,775,807 in the `si-wanxiang-weight-v1` contract. Imported base integers match the pinned source without rescaling except for [documented SI editorial adjustments](chinese/README.md#si-editorial-weight-adjustments); local category additions use editorial weight 10 by default. Leave the weight field empty in a local category to use 10; base and imported category weights must remain explicit. These are ranking weights, not corpus counts or probabilities. Zero is valid and has the existing runtime scoring floor of one.

Use standard CSV quoting for commas and quotes. BOM and CRLF files are accepted; committed files use UTF-8 without BOM and LF. Do not normalize or trim outputs. Identical text/reading pairs may appear in several categories or rows. With `category_overlap: "base"` in `meta.json`, a base identity takes precedence over category copies, including a lower or zero base weight. Imported categories listed in `upstream_categories` take precedence over preserved local copies absent from base. Duplicates within each tier use maximum weight, without summing frequencies. Different Chinese readings and byte-distinct Unicode outputs remain distinct. Distinct English outputs such as `Soul Mate` and `soulmate` may share a typing key and remain separately available. For English, base spelling also overrides case-only category copies. Conflicting casing among nonbase additions is rejected; resolve it explicitly.

No maintained ID or ordering column is required. Compilation assigns internal row IDs by the UTF-8 binary order of reading, then exact text. This makes same-weight ordering deterministic and independent of category filenames, file discovery order or CSV row positions. Reordering rows or renaming nonbase categories does not change the effective dictionary. Moving an overlapping identity into or out of base can change its authoritative weight. The former manually supplied ordinal is removed; equal-weight ordering can differ from the original upstream import order.

To correct a spelling, reading, casing or weight, edit its rows. Edit base to change an overlapping identity; changing a shadowed category weight does not replace base. Among nonbase duplicates, change every higher-weight copy for a lower weight to take effect. To exclude a word, delete all copies of its text/reading pair; there is no overlay that can restore it on the next build. To add a category, create `chinese/technology.csv` or `english/companies.csv`, with the same header, and move/add rows. Flat filenames must match `[a-z][a-z0-9_-]*.csv`; compilation discovers every CSV in each language directory automatically. Keep `base.csv`, even if its rows have been moved into other categories. Empty categories are allowed; an entire language dictionary cannot be empty.

New local entries default to weight **10**, in both languages. Keep all three CSV fields and leave `weight` blank to use that default; explicit numeric weights, including zero, remain supported. Base and metadata-listed upstream categories require explicit weights and never inherit the local default. The Radar updater uses the same default constant for new domains. For example, a local addition can use:

```csv
text,reading,weight
示例词,shi'li'ci,
```

New third-party data still requires the discussion/license review in [CONTRIBUTING.md](../../CONTRIBUTING.md). Add one source-level provenance record to `meta.json` with a unique ID and nonempty inline `metadata` object. Retain its full attribution/license text at the repository-relative `attribution` path and record `attribution_sha256`. The metadata document uses schema version 2; generated manifests hash the complete document. Moving existing entries into a category does not require another source record. SI-authored additions remain covered by SI's GPLv3 license.

## Explicit domain-source updates

The [Radar updater](DOMAINS.md#fetch-and-merge-cloudflare-radar) can fetch and merge
an authenticated top-1000 snapshot into `english/domain.csv`. This is a separate,
user-invoked network operation; ordinary CSV builds remain offline. Tokens belong
in environment variables or an ignored `.env`, never CSV, metadata or app resources.
Imported Radar records retain their CC BY-NC 4.0 attribution and full license;
the software's GPLv3 license does not remove the data's NonCommercial conditions.

## Compile and verify

Run from the repository root with Python 3.9+ (standard library only):

```sh
python3 scripts/csv_dictionary.py build
python3 scripts/csv_dictionary.py build --check
python3 -m unittest discover -s Tests/VocabularyTests -v
./scripts/test.sh
./scripts/build.sh
```

`--language chinese` or `--language english` builds/checks one language. The existing `msime_dictionary.py build` and `english_dictionary.py build` commands delegate to this compiler. The Chinese compatibility check additionally verifies the separately pinned context resources. The separate `wanxiang_dictionary.py fetch` / `convert` commands explicitly refresh both bases and the imported categories from the reviewed source lock. Ordinary CSV builds never invoke them; reimporting base replaces manual base edits. Review an upstream revision and update its hashes/licensing before adoption.

Outputs remain `mac/SI/Core/Resources/Chinese/si-pinyin.sqlite` and `mac/SI/Core/Resources/English/si-english.sqlite`, with a manifest beside each database. The databases and SQLite sidecars are Git-ignored; CSV sources, manifests and attribution remain tracked. Run `python3 scripts/csv_dictionary.py build` in a fresh clone before building/testing SI, and again after editing source vocabulary. The app and package use the same generated local files; ordinary build/test scripts do not generate them. A manifest records the CSV files, hashes, counts, metadata hash and runtime checksum. These are generated artifacts. Do not edit them. `--check` stages a fresh build and compares schema, metadata, exact rows/generated IDs and indexes, allowing equivalent SQLite files from other versions, while checking the retained binary hash. It never replaces packaged outputs. Invalid source input cannot replace existing outputs; a two-language build validates both before publishing either.

The package and app already bundle these same databases, so normal app compilation needs no Python, upstream import or network. Typing reads SQLite and never parses CSV. The current bases replace the former vocabulary and weights; category supplements remain preserved. Tie order is now derived from content; this makes no ranking-quality or host-compatibility claim. Private personal phrases and app vocabulary archives are separate and never read by these tools.
