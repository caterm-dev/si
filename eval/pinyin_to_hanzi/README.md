# Pinyin to Hanzi: lexical-v1

[Dev data](lexical-v1/dev.jsonl) has 69 unique inputs from the existing 73 validation
CSV pairs; [test data](lexical-v1/test.jsonl) has 64 unique inputs from 69 test
pairs. Same-input homophones are grouped into `references`; for example, both
潮湿 and 超市 are accepted for `chaoshi`. The original character/short-word scope
and split assignments are preserved; validation is named dev in this registry.

The [sources](lexical-v1/sources/) contain the exact four original held-out CSVs
and their provenance; each case points to its source file/line. This frozen copy
is independent of later training-source edits. There is no automatic sentence,
Pinyin, spelling-noise or split generation. Original training/validation/test
sources remain under `llm/pinyin_to_text/data/pinyin-csv/` for compatibility with
existing training experiments; they are not read by the shared scorer.

These are existing inspected synthetic lexical regression cases, not a new
independent holdout. Do not train on the evaluation rows. Different future
training corpora need their own overlap audit. Sentence conversion, noisy input
and mixed/English preservation need their own suites/tracks; they are not
implied by lexical results. Use the [shared protocol](../README.md) and compare
actual generated outputs, not teacher-forced loss/perplexity.
