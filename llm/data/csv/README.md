# Maintained static CSV data

This is the current editable source of training data. Maintain CSV rows directly; there is no automatic sentence/Pinyin/typo generation or random split in preparation.

```text
train/city.csv          Training examples about cities
train/company.csv       Training examples about companies/work
train/chat_daily.csv    Short daily chat phrases
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

Do not put the same correct text or normalized-identical input in different splits, including its typo variants. Put related template/paraphrase variants into the same split manually; the importer cannot detect semantic similarity. It reports conflicting file/line locations instead of moving your rows. All three directories need nonempty data. No test data is used for tokenizer fitting, training or checkpoint selection.

The initial static collection was materialized once from the previous SI-authored Chinese starter and original fixtures, preserving their existing split assignments and all spelling-error examples. Clean city/company rows are in their named files; previously generated errors are now actual static rows in `typos.csv`, `english_typos.csv` or `mixed_typos.csv`. Files are not regenerated from the old seed. Import yields **16,312 training**, **1,361 validation** and **1,300 test** unique pairs (18,973 total); one exact duplicate in the old 18,974-row collection is deduplicated. These are synthetic starter examples, not real conversations, a frequency-ranked vocabulary or an independent quality benchmark.

`provenance.json` declares GPLv3 and SI authorship for this collection. Its default applies to new SI-authored files, with optional per-file declarations under `files` for other reviewed sources. It is a rights/provenance record, not automatic licensing of any material copied into the folder. Keep third-party origin, exact revision and required attribution with each imported source; never add private input history or personal phrases.

Prepare a new immutable version with:

```sh
./llm/scripts/prepare.sh --csv-root llm/data/csv --output llm/data/prepared/static-csv-v2
```

The importer freezes exact CSV bytes, hashes and declarations alongside model-ready JSONL/tokenizer files. Editing a CSV later does not change that snapshot. Choose a new prepared directory and new run after editing data; do not replace a stopped run's dataset and try to resume it. Existing old checkpoints/prepared datasets are preserved. See [the complete training guide](../../README.md).
