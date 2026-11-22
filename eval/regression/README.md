# Candidate window regression suite

Append independently authored failures and controls here. Each JSONL row
records a spelling, synthetic preceding text, languages, references,
and origin. Keep these fixtures separate from model training and the frozen
ranking benchmark. The historical known-miss flags describe the legacy
route. The current assertions use statistical conversion and check the exact window
rank of each whole reference.

## Evaluation entry points

- The Swift window regression runs synchronous statistical conversion with an empty
  profile, correction off as the primary check and conservative correction
  on as the second check. The separate preference test injects the authored
  river preference in each correction mode.

From the repository root, run with an existing Release build.

```sh
SI_TEST_ENGINE_RESOURCE_DIRECTORY="$PWD/.build/xcode/Build/Products/Release/SI.app/Contents/Resources/SIEngine" \
  ./scripts/test.sh --filter WindowRankingRegressionTests
```
