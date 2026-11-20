# 100,000 syllable-labeled Pinyin examples

| Split | First batch | Additional batch | Combined | With preceding text |
| --- | ---: | ---: | ---: | ---: |
| Train | [48,000](train/examples.csv) | [48,000](train/additional.csv) | 96,000 | 9,609 |
| Validation | [1,000](validation/examples.csv) | [1,000](validation/additional.csv) | 2,000 | 204 |
| Test | [1,000](test/examples.csv) | [1,000](test/additional.csv) | 2,000 | 187 |

Each row has `input,target,context,syllables`. `input` concatenates the
lowercase, toneless syllables. `syllables` uses single spaces and preserves
the SI dictionary's `v` spelling for ü. `context` is the text immediately
preceding the target, or empty for lexical conversion. The encoder reads
the supplied syllable sequence and preceding text.

Each batch contains 45,000 standalone lexical rows and 5,000 contextual rows.
Dictionary weights and length quotas guide selection. The first batch includes
one- to six-character lexical entries. The additional batch selects two- to
six-character entries and requires each normalized spelling and target to be
absent from the first batch. Contextual rows split an existing longer entry
into preceding text and a target. The full reading and both subentry readings
must agree exactly.
Selection limits repeated contexts and targets, and each longer source text
contributes at most one row. The original longer text is excluded as a
context-free target. These dictionary-derived examples exercise contextual
conversion from attested dictionary entries. They provide no independent
annotations of natural sentence or word boundaries.

The additional batch keeps the first batch's CSV files and split assignments.
Examples with the same normalized spelling or target stay in the same split,
including connected groups of homophones and alternate readings. Single-character
targets stay in training. At most three distinct syllable paths are retained
per spelling. Validation and test samples are held out from this selection and
share its dictionary source.

## Source and reproduction

The pinned source is SI's [`Data/Chinese/base.csv`](../../../../Data/Chinese/base.csv),
with Wanxiang base vocabulary by amzxyz and the rime-wanxiang-data contributors
and SI lexical additions. The selection, formatting and contextual cuts are
modifications by SI. The source attribution, upstream revision and CC BY 4.0
license are recorded in the [Wanxiang notice](../../../../mac/SI/Core/Resources/English/Wanxiang-NOTICE.txt)
and [license text](../../../../mac/SI/Core/Resources/English/Wanxiang-CC-BY-4.0.txt).
The [SI Chinese dictionary notices](../../../../mac/SI/Core/Resources/Chinese/NOTICE.txt)
document the accompanying attribution. [Provenance](provenance.json) pins the
source SHA-256 and records each output CSV's hash. Only the pinned lexicon is
used for materialization.

Regenerate into a new directory and pass it explicitly to data preparation.

```sh
python3 -m llm.pinyin_to_text.csv_data.build_syllable_collection --output /tmp/si-syllable-csv
./llm/pinyin_to_text/scripts/data.sh --csv-root /tmp/si-syllable-csv --output /tmp/si-syllable-ready
```
