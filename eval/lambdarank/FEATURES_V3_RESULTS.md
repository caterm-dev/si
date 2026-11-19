# V3 feature development check, 2026-11-19

The offline schema now contains 43 features: frequency (5), internal grams (6),
whole-candidate context (6), spelling (4), structure (4), user lexicon (6), user
grams (6), and correction (6). See [the contract](README.md#candidate-and-feature-contract).
Production does not load these models.

## Controlled comparison before typo expansion

The immutable `features-v2-control-20261119`, `features-v3-control-20261119` and
`features-v3-correction-20261119` prepared bundles used the same 88 training and
42 validation requests and resource pair. Candidate identities, order and labels
were checked equal across all three bundles. No corrected candidates occurred.

| Ranking | Validation Top-1 | Top-5 | MRR |
| --- | --- | --- | --- |
| Existing Rust order | 25/42 | 36/42 | 0.7129 |
| V2, 38 features | 30/42 | 35/42 | 0.7785 |
| V3, 43 features | 28/42 | 36/42 | 0.7469 |

V3 does not establish an overall improvement over V2. Ten V3 removal comparisons
are retained under ignored `runs/features-v3-ablation-20261119/`; these use the
same development validation, so the best variant is not independent test evidence.

## Explicit typo examples

Four authored typo variants were added to each split, preserving their original
families, for 92 training and 46 validation requests. They were not selected for
reachability. `prepared/features-v3-typos-20261119/` contains 12 corrected training
candidates and 11 corrected validation candidates. Both models below use this
same frozen pool, including the same corrections.

| Ranking | Validation Top-1 | Top-5 | MRR |
| --- | --- | --- | --- |
| Existing Rust order | 25/46 | 37/46 | 0.6586 |
| V3 all | 30/46 | 38/46 | 0.7205 |
| V3 without correction feature group | 30/46 | 38/46 | 0.7205 |

The six correction features have zero splits in this trained model. Four typo
validation queries yield two retrieved gold answers and two missing answers;
Top-1 on that tiny category is 2/4. This verifies extraction/training but does not
establish correction-feature utility. Retrieval failures cannot be fixed by reranking.
There are no user snapshots in these datasets, so user feature quality remains
unmeasured. No private profile was read. User-statistic arithmetic and availability
are covered by synthetic Rust fixtures.

## Verification

- Cargo workspace tests, formatting and diff whitespace checks passed.
- Nine Python pipeline tests passed, including real correction export and nulls.
- Frozen 220-query regression dataset integrity check passed; no fitting used it.
- Release CLI built; saved models were checked for prediction equivalence.
- V3 model reload/evaluation matched the saved report.
- Base/user synthetic fixtures verify full-candidate external trigrams, unknown
  versus known-empty context, correction types/costs, and unchanged ordinary
  conversion results after diagnostics are removed.

Validation is used for early stopping and feature exploration. These small
synthetic datasets are not production accuracy estimates. Prepared data, models,
checksums and detailed reports remain ignored local artifacts.
