# Focused Pinyin characters and words

This is the default editable source for the small Pinyin-only experiment. It contains explicit UTF-8 CSV rows; preparation never generates Pinyin, sentences, character decompositions, spelling errors or random splits.

```text
train/characters.csv       937 character/reading pairs
train/words.csv          1,084 short lexical entries
validation/characters.csv    6 character/reading pairs
validation/words.csv        67 short lexical entries
test/characters.csv         11 character/reading pairs
test/words.csv              58 short lexical entries
```

The initial collection has 2,163 pairs: 2,021 train, 73 validation and 69 test. A character can have several readings; several characters can share a reading. Counts are pairs, not distinct characters or input cases. Evaluation groups an identical input's accepted outputs together, so case counts can be smaller than CSV row counts. These small held-out sets are synthetic fixtures, not a production benchmark.

Maintain only two columns:

```csv
input,target
ni,你
hao,好
nihao,你好
beijing,北京
shurufa,输入法
```

Keep single Han outputs in `characters.csv`, and two/three-Han lexical entries in `words.csv`. Inputs are continuous lowercase toneless Pinyin; retained examples use ASCII spellings. The initial word selection includes pronouns, greetings, common nouns/verbs, cities and office terms. It excludes the old short-sentence category, longer phrases, sentence-final responses, chat templates, English/mixed examples and typo sources. For example, `nihao,你好` is included; `womenzaijia,我们在家` is outside this experiment. This scope does not implement sentence conversion, learned English preservation or typo correction.

Multiple rows such as `shi,是` and `shi,时` are intentional. Keep every identical input and every identical output in one split, including polyphonic characters and their alternative readings. The importer rejects cross-split normalized input or target overlap and never silently moves data. A held-out word may contain characters learned from training words, allowing composition to be evaluated without reusing its whole output. Keep validation/test fixed while comparing models.

## Initial selection and provenance

The October 28, 2026 selection reused existing SI-authored `words.csv`, `city.csv` and `company.csv` entries from [the earlier collection](../csv/README.md), preserving each retained pair's split. It kept 1-3-Han entries with continuous Pinyin and removed the historical `words_short_phrases.csv` category at revision `072a857`, reviewed phrase targets and sentence-final particles. Longer words/idioms are deferred; length alone is not a linguistic definition of a word.

There were only 170 explicit training character pairs. To improve coverage, a one-time alignment decomposed retained **training words only** into their existing syllable/character pairs. The existing [SI character-reading inventory](../../../../Data/Vocabulary/chinese/base.csv) validated a unique segmentation of each full spelling. This added 767 training character pairs, with every new target character and every spelling byte already present in an SI-authored training word. No new lexical text was imported. A derived character pair was excluded if its input or output belonged to validation/test. No held-out word was decomposed into training data. All eligible training word alignments were unique; this is a reading consistency check, not independent human review of every lexical item.

[selection.json](selection.json) records the original source hashes, initial selection rules/counts, excluded targets and the inventory hash. It is an audit of the one-time materialization, not a generator or source of training rows. [provenance.json](provenance.json) declares GPL-3.0-only SI authorship. Existing inventory provenance and notices remain in [Data/Vocabulary/meta.json](../../../../Data/Vocabulary/meta.json) and [Data/Chinese/MSIME/NOTICE.md](../../../../Data/Chinese/MSIME/NOTICE.md); the training source adds no external download, engine or dependency. Later CSV edits are authoritative and need a new prepared snapshot; initial selection counts remain historical.

The initial dataset is deliberately limited. Unseen Pinyin, characters, words and homophone ranking remain quality risks. Character coverage does not prove word conversion quality. Evaluate actual generated candidates, and distinguish memorization from held-out generalization.
