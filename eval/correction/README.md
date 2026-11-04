# Correction: synthetic-v1

[Dev data](synthetic-v1/dev.jsonl) contains 25 cases; [test data](synthetic-v1/test.jsonl)
contains 55. Each split covers noisy Pinyin-to-Hanzi, Chinese character typos,
English spelling, mixed technical names and unchanged-text controls. Each row
declares an intended exact transformation, not a general autocorrection policy.
Identifiers, casing, punctuation, composed/decomposed accents, supplementary Han
and emoji must be preserved in the unchanged controls.

The fixed pairs are newly SI-authored synthetic regression fixtures, not observed
typing or independently annotated errors. They are intentionally small; this
does not implement correction in the app or establish real-error coverage.
No model-corpus overlap audit has been performed. Keep related future variants
in the same family/split and publish a new suite version for changes.

Use the [shared prediction/scoring protocol](../README.md). Predictions are ordered
`outputs`, not supplied-pool indices. Read per-track exact accuracy and CER along
with correction accuracy and overcorrection rate; the literal baseline should
pass unchanged controls and fail cases requiring edits.
