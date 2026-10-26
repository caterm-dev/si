# Static expansion to 50,000 samples

On October 26, 2026, 31,027 SI-authored synthetic training pairs were added to the existing 18,973-sample collection. The maintained CSVs contain 50,000 unique `(input, target, language)` samples: 47,339 training, 1,361 validation and 1,300 test. There are 50,001 physical data rows because the original training collection contains one exact duplicate; it remains preserved and preparation deduplicates it.

## Authorship and rights

All additions are original synthetic examples authored for SI under GPL-3.0-only. Chinese phrases, explicit toneless Pinyin readings, English sentences and mixed-language frames were composed locally. No third-party corpus, conversation logs, personal phrase archive, clipboard, document or app history was imported. Synthetic first names are placeholders. Product and format names appear only as literal technical terms.

The existing packaged SI dictionary was used only to check character-reading compatibility; its lexical entries were not copied into the training data. This check is not proof of contextual pronunciation or natural language quality. The data does not establish production vocabulary coverage or representative conversion accuracy.

## Added training pairs

| Destination | New pairs | Content |
| --- | ---: | --- |
| `train/chat.csv` | 22,000 | Complete Pinyin to Chinese phrases across 25 semantic families |
| `train/english.csv` | 5,000 | 2,500 English sentences, each with an exact-copy input and a space-removed input |
| `train/mixed.csv` | 3,000 | Pinyin mixed with exact filenames, tool names and technical terms |
| `train/typos.csv` | 1,027 | One adjacent interior letter transposition per selected new training target |

Chinese coverage comprises everyday activities and plans (5,436), object locations and reminders (3,623), meeting places (1,812), document requests and follow-ups (3,624), travel plans and stays (1,810), cooking and meals (2,260), and learning plans/resources/routines (3,435). Mixed coverage comprises file actions (1,260), technical topics (1,260) and file status messages (480).

The one-time composition process used compatible phrase slots, including times, people, activities, objects, locations, documents, dishes and study topics. Chinese and mixed families were traversed round-robin in deterministic SHA-256 order over `(input, target, language)`. English sentences used deterministic SHA-256 order, with both input forms kept together. Existing sample identities and normalized validation/test inputs or targets were excluded before selection. Typo examples were derived only from the newly added training sentences, using a deterministic interior unequal-letter swap; their intended target stays unchanged. They model an artificial error mechanism, not measured human typo frequencies.

The delivered CSV rows are authoritative and remain directly editable. Preparation and training do not run a content generator or add random noise. No new pronunciation dependency, model architecture or training configuration was introduced.

## Verification and limits

- All 18,973 original sample identities remain in their original splits. The original contents of the four extended CSVs remain byte-for-byte prefixes; the other 20 CSV files are unchanged, including every validation/test file.
- All 31,027 additions are distinct and increase the unique count by exactly 31,027. Normalized input/target cross-split overlap checks pass.
- All 25,000 clean Chinese/mixed additions pass exact character-reading alignment against the existing SI dictionary, with ASCII bytes matched literally. Pinyin was authored explicitly; no readings were inferred during preparation.
- All 2,500 English sentence pairs preserve target spelling, case and punctuation. Their continuous-input variants remove only ASCII spaces.
- Every new typo has its clean target and spelling in the new training chat set and differs by exactly one adjacent transposition.
- Full preparation with the production 0.403B config succeeds. Maximum encoded lengths are 71 input and 71 target tokens in training, below the configured 256/128 limits; validation maxima are 35/25 and test maxima are 31/15.
- All 34 framework tests pass, including the MPS numerical check. A separate smoke run using the expanded CSV root completes four small-model CPU training/resume steps, three-case validation/test evaluations and literal-fallback checks. Every frozen bundle file hash and all 50,000 JSONL sample identities match the maintained CSVs. These checks do not measure the formal model's conversion quality.

These are correlated template combinations, not 31,027 independently observed utterances. Selected examples and all phrase families were inspected, but every sentence has not had independent human review. Character-level alignment accepts multiple readings and cannot validate grammar or word sense. Validation/test remain small synthetic fixtures, with only six English cases in each and three mixed cases in test; keeping them unchanged prevents changing their contents but does not create an independent real-world benchmark or rule out semantic/template overlap. Evaluate external data before making quality claims. No full model training was started for this expansion.

## Use the expanded snapshot

The verified immutable bundle is `llm/data/prepared/static-csv-50k-v1`, with dataset ID `6cd3c06723846a9f2f80b57645e01cf94486e25a4920d159fdb98d7b4a4831fb`. Prepared artifacts are ignored by Git; recreate a fresh version from maintained CSVs when needed:

```sh
./llm/scripts/prepare.sh --output llm/data/prepared/static-csv-50k-v1
./llm/scripts/train.sh --data llm/data/prepared/static-csv-50k-v1 \
  --run llm/runs/0.4b-static-csv-50k-v1
```

Run each command only when its output directory does not already exist. Existing presets, frozen datasets, trained weights and runs remain unchanged. A run using the previous dataset cannot resume on the expanded one.
