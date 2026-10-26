# Training data

The current source is [csv/](csv/README.md): maintained static CSV files organized by `train/`, `validation/` and `test/`, with filenames such as `city.csv`, `company.csv` and `chat.csv` as source groups. Chinese files need only `input,target`; `language` is optional. Preparation reads exactly the rows you maintain, validates split separation and writes a versioned snapshot. It does not generate data or randomize split assignments.

Use `./llm/scripts/prepare.sh --output NEW_DIRECTORY`; see [the training guide](../README.md) for commands and experiment management. Prepared files, source snapshots, checkpoints and reports are ignored by Git. Editable static CSVs and their provenance declaration are retained in source.

The collection contains 50,000 unique prepared samples after deduplication: 47,339 training, 1,361 validation and 1,300 test. The [50,000-sample expansion](csv/EXPANSION_50K.md) adds 31,027 original synthetic training pairs while preserving every original sample and all validation/test files. Add or modify CSVs directly for later versions. Template seeds, automatic generators, old raw/prepared data and source-manifest import paths have been removed. Existing trained weights are preserved for inference, but their removed datasets cannot be used for resume.

All current data is SI-authored synthetic material under GPLv3. New external corpora require reviewed origin, license, revision and attribution. No app memory, user phrase archive, private document, clipboard or chronological typing history is a source.
