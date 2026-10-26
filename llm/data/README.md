# Training data

The current source is [csv/](csv/README.md): maintained static CSV files organized by `train/`, `validation/` and `test/`, with filenames such as `city.csv`, `company.csv` and `chat_daily.csv` as source groups. Chinese files need only `input,target`; `language` is optional. Preparation reads exactly the rows you maintain, validates split separation and writes a versioned snapshot. It does not generate data or randomize split assignments.

Use `./llm/scripts/prepare.sh --output NEW_DIRECTORY`; see [the training guide](../README.md) for commands and experiment management. Prepared files, source snapshots, checkpoints and reports are ignored by Git. Editable static CSVs and their provenance declaration are retained in source.

The initial CSV collection preserves the previous starter's data and split assignments, including explicit typo rows. It contains 18,973 unique prepared samples after deduplication. Add or modify CSVs directly for later versions; do not regenerate them from `seed.json`.

Historical sources remain for reproducibility: `fixtures/pairs.jsonl` has 92 original workflow fixtures, and [chinese-starter/](chinese-starter/README.md) records the initial template-generated corpus and MPS run. The old source manifests, generator and JSONL importer are legacy paths; they are not part of the current CSV workflow. Their old prepared artifacts and checkpoints remain intact.

All current data is SI-authored synthetic material under GPLv3. New external corpora require reviewed origin, license, revision and attribution. No app memory, user phrase archive, private document, clipboard or chronological typing history is a source.
