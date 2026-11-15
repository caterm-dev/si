# Chinese vocabulary migration

`scripts/migrate_chinese_vocabulary.py` converts only
`Data/Vocabulary/chinese/base.csv` and all CSVs recursively under
`Data/Vocabulary/chinese/phrase/` into `Data/Chinese/base.csv`. Other category
files such as `movie.csv` and `geography.csv` are neither read nor changed.
It does not move/delete the inputs or copy English data. The runtime compiler
now reads `Data/Chinese/*.csv` and `Data/English/*.csv`; the migration source
paths above are historical inputs, so rerunning migration requires a retained
legacy source directory selected with `--source`.

Run from the repository root using the existing HanLP environment:

```sh
# Only needed when preparing a new environment/model cache:
python3 -m venv corpus/.venv
corpus/.venv/bin/python -m pip install -r corpus/requirements-hanlp.txt
corpus/.venv/bin/python scripts/migrate_chinese_vocabulary.py --fetch-model

# Offline coarse-grained conversion with the locked local model (CPU by default):
corpus/.venv/bin/python scripts/migrate_chinese_vocabulary.py --source /path/to/legacy/chinese --output /tmp/si-chinese-base.csv
# Optional Apple Silicon acceleration:
corpus/.venv/bin/python scripts/migrate_chinese_vocabulary.py --source /path/to/legacy/chinese --output /tmp/si-chinese-base.csv --device mps
# Optional fine-grained conversion (prepare its separate model cache first):
corpus/.venv/bin/python scripts/migrate_chinese_vocabulary.py --granularity fine --fetch-model
corpus/.venv/bin/python scripts/migrate_chinese_vocabulary.py --source /path/to/legacy/chinese --output /tmp/si-chinese-fine.csv --granularity fine
```

The default is HanLP 2.1.3's `COARSE_ELECTRA_SMALL_ZH`, pinned to
`https://file.hankcs.com/hanlp/tok/coarse_electra_small_20220616_012050.zip`.
See the [official pretrained tokenizers](https://hanlp.hankcs.com/docs/api/hanlp/pretrained/tok.html).
The coarse model uses the original `corpus/.cache/hanlp/model-lock.json`.
`--granularity fine` selects `FINE_ELECTRA_SMALL_ZH` and its separate
`corpus/.cache/hanlp-fine/model-lock.json`.
The corpus tools retain their coarse default. The migration script reuses the
existing dependency pins and offline loader from `corpus/hanlp_words.py`.
`--fetch-model` explicitly downloads/locks only the selected model, then exits;
ordinary conversion never downloads or falls back to a different model. To
prepare a missing coarse cache, use `--fetch-model`.
No vocabulary is forced into HanLP. Model terms are recorded in each lock:
the model remains a local research/teaching tool and is not bundled with the
app. Original vocabulary attribution and licenses
are preserved in the [packaged notices](../../mac/SI/Core/Resources/Chinese/).
See the [HanLP tokenizer API](https://hanlp.hankcs.com/docs/api/hanlp/components/tokenizers/transformer.html).

Output is UTF-8 CSV with exactly `text,reading,weight` columns. Each token
occurrence contributes its source row's complete integer weight. For example,
`说,shuo,1000` plus `说回家,shuo'hui'jia,760`, segmented as `说 / 回家`,
produces `说,shuo,1760` and `回家,hui'jia,760` (plus any other contributions).
An unsplit row contributes once. Repeated tokens in a row contribute repeatedly;
duplicate input rows within the selected inputs also contribute separately. This migration
intentionally sums the raw CSV rows instead of applying the old compiler's
base/category precedence. Split phrases are replaced by their tokens.

Identity is exact `(text, reading)`, so different readings remain separate.
Readings are sliced from the original row, never regenerated using a Pinyin
model. Punctuation/spacing consumes no syllables; standalone punctuation/space
tokens are omitted. The four existing non-character-aligned movie spellings
(`F`, `X`, `33`, `II`) have explicit source-reading aliases. Unsupported alignment,
changed tokenizer text or a token boundary inside an indivisible alias fails
with its source file/line instead of guessing a reading. Blank weights default
to 10; zero remains valid. Summed weights must fit a signed 64-bit integer.

Rows are sorted by UTF-8 reading, then text. Input is processed in bounded
chunks; aggregate word/readings remain in memory. `--batch-size`, `--chunk-rows`
and `--threads` control processing; `--source` and `--output` select other paths.
`--source` must contain `base.csv`; its `phrase/` directory is optional, and
only CSV files in that directory tree are included alongside `base.csv`.
The output must be outside the source tree. A complete conversion atomically
replaces its output CSV; failure preserves any previous output. Rerunning reads
only the original inputs, so it does not accumulate the previous output again.
Switching granularity requires a new complete run; a running process keeps its
loaded model. Use `--output /tmp/si-chinese-fine.csv` to compare against an
existing coarse result without replacing it (also select `--granularity fine`).

Synthetic checks, without model installation or downloads:

```sh
python3 -m unittest discover -s Tests/VocabularyTests -p test_migrate_chinese_vocabulary.py -v
```
