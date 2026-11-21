# Growing candidate window regression suite

Append independently authored failures and controls here. Each JSONL row
records a spelling, synthetic preceding text, enabled languages, references,
and its origin. This suite is used for regression checks and stays separate
from model training and the frozen ranking benchmark.

The test runs the actual candidate window with packaged resources. It checks
whole-candidate visibility, first place, and membership in the first four
window slots. The known-miss flags record current first-choice or first-four
failures. They still require the reference to be selectable and allow a fix
to pass immediately. Remove the flags after verifying the relevant fix.

From the repository root, run with an existing Release build.

```sh
SI_TEST_ENGINE_RESOURCE_DIRECTORY="$PWD/.build/xcode/Build/Products/Release/SI.app/Contents/Resources/SIEngine" \
  ./scripts/test.sh --filter regressionQueriesUseTheActualWindow
```
