# Maintained static CSV data

This is the current editable source of training data. Maintain CSV rows directly; there is no automatic sentence/Pinyin/typo generation or random split in preparation.

```text
train/city.csv          Training examples about cities
train/company.csv       Training examples about companies/work
train/words.csv         General Chinese vocabulary (merged categories)
train/chat.csv          Chat phrases (merged categories)
train/typos.csv         Explicit Chinese typo → correct text pairs
train/english.csv       English identity/correction examples
validation/*.csv        Development validation examples
test/*.csv              Held-out test examples
```

Chinese files use two columns:

```csv
input,target
beijing,北京
shanghai,上海
```

The optional `language` column accepts `zh`, `en` or `mixed`; omitted means Chinese (`zh`). English and mixed files include the column. No `group`, `noise` or `clean_input` field is needed. The CSV filename is the source group, and the enclosing directory determines its split. Categories may repeat across splits; identical input/target strings may not. Nested groups such as `train/business/company.csv` work without editing code.

Add a new `.csv` file and it will be included the next time you prepare a dataset. Save as UTF-8 (BOM accepted). Standard CSV quoting handles commas and quotes. Blank values, control characters, malformed headers/row widths, unsupported languages and oversized examples are rejected. Output spelling/casing is preserved exactly. Exact duplicate pairs inside one split are deduplicated, retaining all source group names.

Vocabulary is maintained in one `words.csv` per split: 1,350 training, 75 validation and 74 test pairs. Training consolidates the previous twelve `words_*.csv` files; validation and test each consolidate eleven files. Every pair and its split are preserved. City/company/chat/error sources retain their own files. Existing prepared snapshots are immutable; prepare a new version to use changed source grouping.

Chat phrases are maintained in one `chat.csv` per split: 26,001 training, 373 validation and 354 test pairs (26,728 total). The original 4,728 pairs consolidate the previous 59 `chat*.csv` files into three files; 22,000 new training phrases were added in the [50,000-sample expansion](EXPANSION_50K.md). Every original row and its split are preserved. With vocabulary categories also merged, the collection contains 24 CSV files. Prepared snapshots and existing runs retain their original source groups; prepare a new version to use edited CSVs.

Do not put the same correct text or normalized-identical input in different splits, including its typo variants. Put related template/paraphrase variants into the same split manually; the importer cannot detect semantic similarity. It reports conflicting file/line locations instead of moving your rows. All three directories need nonempty data. No test data is used for tokenizer fitting, training or checkpoint selection.

The initial static collection was materialized once from the previous SI-authored Chinese starter and original fixtures, preserving their existing split assignments and all spelling-error examples. Clean city/company rows are in their named files; previously generated errors are now actual static rows in `typos.csv`, `english_typos.csv` or `mixed_typos.csv`. The initial version contained 18,973 unique pairs. The October 26, 2026 expansion adds 22,000 Chinese chat, 5,000 English, 3,000 mixed and 1,027 explicit typo pairs to training only. There is no seed or sentence-generation script in the current project. Import now yields **47,339 training**, **1,361 validation** and **1,300 test** unique pairs (**50,000 total**); the original exact duplicate is still deduplicated. These are synthetic examples with correlated template combinations, not real conversations, a frequency-ranked vocabulary or an independent quality benchmark. See [authorship, checks and limitations](EXPANSION_50K.md).

`provenance.json` declares GPLv3 and SI authorship for this collection. Its default applies to new SI-authored files, with optional per-file declarations under `files` for other reviewed sources. It is a rights/provenance record, not automatic licensing of any material copied into the folder. Keep third-party origin, exact revision and required attribution with each imported source; never add private input history or personal phrases.

Prepare a new immutable version with:

```sh
./llm/scripts/prepare.sh --csv-root llm/data/csv --output llm/data/prepared/static-csv-v2
```

The importer freezes exact CSV bytes, hashes and declarations alongside model-ready JSONL/tokenizer files. Editing a CSV later does not change that snapshot. Choose a new prepared directory and new run after editing data; do not replace a stopped run's dataset and try to resume it. Current CSV prepared snapshots are preserved. Previously trained weights remain available for inference; their removed old datasets/configuration are not available for resume. See [the complete training guide](../../README.md).
