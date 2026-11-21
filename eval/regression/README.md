# Candidate window regression suite

Append independently authored failures and controls here. Each JSONL row
records a spelling, synthetic preceding text, languages, references,
and origin. Keep these fixtures separate from model training and the frozen
ranking benchmark. The historical known-miss flags describe the legacy
route. The current assertions use the App route and check the exact window
rank of each whole reference.

## Reference measurements

The comparison anchor is ac2fb6b using the fixed installed LambdaRank
model and the actual Swift window. Counts below are Top-1 / Top-4.
App correction defaults off. The primary profile is empty. Six of the
185 development queries and one of the 17 regression queries have authored
prior choices. The preference slice injects these into an in-memory
profile only to check the effect of ranking preferences. No user
dictionary, archive or live selections are read. All labels are unchanged.

| Correction off | Queries | Empty S | Empty LTR | Empty X=6 | Fixture S | Fixture LTR | Fixture X=6 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Clean | 138 | 101 / 118 | 84 / 110 | 103 / 122 | 100 / 120 | 85 / 110 | 101 / 123 |
| Context | 26 | 9 / 14 | 14 / 24 | 13 / 18 | 8 / 16 | 15 / 24 | 11 / 19 |
| Regression | 17 | 15 / 16 | 14 / 15 | 16 / 17 | 14 / 16 | 14 / 15 | 15 / 17 |

With conservative correction active for every request, the App's X=6
route has 133 / 155 on all 185 queries with an empty profile, including
103 / 122 on the 138 clean queries and 30 / 33 on the 47 correction
queries. With authored prior choices the corresponding counts are
131 / 156, 101 / 123 and 30 / 33. The statistical leader remains visible
on all these paths. The six-bit evaluations with correction off are
controlled comparisons and are separate from the App default.

Per-query regression results with correction off. Each cell lists the
reference's Swift window rank for S / unrestricted LTR / X=6.

| Input | Preceding text | Reference | Empty profile | Fixture profile |
| --- | --- | --- | --- | --- |
| xiandingge | — | 先定个 | 1 / 5 / 1 | 1 / 5 / 1 |
| xiandinggei | — | 限定给 | 1 / 5 / 1 | 1 / 5 / 1 |
| shangganqing | — | 伤感情 | 1 / 1 / 1 | 1 / 1 / 1 |
| xianding | — | 限定 | 1 / 1 / 1 | 1 / 1 / 1 |
| jinchao | — | 金超 | 1 / 1 / 1 | 1 / 1 / 1 |
| can | We know that you  | can | 1 / 1 / 1 | 1 / 1 / 1 |
| he | I think that  | he | 1 / 1 / 1 | 1 / 1 / 1 |
| you | Thanks to  | you | 1 / 1 / 1 | 1 / 1 / 1 |
| fan | The cooling system uses a  | fan | 1 / 1 / 1 | 1 / 1 / 1 |
| ban | The club voted to  | ban | 8 / 3 / 3 | 8 / 3 / 3 |
| pin | Please enter the security  | pin | 1 / 1 / 1 | 1 / 1 / 1 |
| hang | Use this hook to  | hang | 1 / 1 / 1 | 1 / 1 / 1 |
| sun | The planets orbit the  | sun | 1 / 1 / 1 | 1 / 1 / 1 |
| run | To start the script,  | run | 1 / 1 / 1 | 1 / 1 / 1 |
| cannot | This command  | cannot | 1 / 1 / 1 | 1 / 1 / 1 |
| he | 这条 | 河 | 1 / 1 / 1 | 2 / 1 / 2 |
| shi | 九加一等于 | 十 | 2 / 1 / 1 | 2 / 1 / 1 |

## Evaluation entry points

- The Swift window regression runs the actual App policy with an empty
  profile, correction off as the primary check and conservative correction
  on as the second check. The separate preference test injects the authored
  river preference in each correction mode.
- The 185-query window evaluation uses an empty profile and correction off
  as the primary run, then repeats with conservative correction on for
  all 185 queries. Report the 138 clean and 47 correction rows separately.
  Prior choices are enabled only for the explicit preference comparison.
- The generated-spelling differential uses source text and enabled
  languages only, with correction off and no preferences or host text. It
  compares full Rust candidate pools. The Swift window evaluation
  supplies the presentation-level checks.
- The offline LambdaRank training and scoring tools have their own
  explicitly supplied snapshots. See [their protocol](../lambdarank/README.md)
  for that setup.

From the repository root, run with an existing Release build.

```sh
SI_TEST_ENGINE_RESOURCE_DIRECTORY="$PWD/.build/xcode/Build/Products/Release/SI.app/Contents/Resources/SIEngine" \
  ./scripts/test.sh --filter WindowRankingRegressionTests
```
