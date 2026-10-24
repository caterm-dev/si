# Setup validation — October 24, 2026

## Dataset expansion

- `python3 llm/generate_data.py --check`: passed; exactly 10,000 seed records,
  split into 8,000 training, 1,000 validation and 1,000 test examples.
- `python3 llm/prepare.py --check`: passed for the expanded source and exports.
- `python3 -m unittest discover -s llm/tests -v`: 24 tests passed, including
  reproducibility, duplicate/split/target checks, single-edit spelling errors,
  partial/initial mappings, exact English bytes and prediction suffixes.
- All 10,000 records were tokenized through the local Qwen3.5-0.8B-4bit
  tokenizer using the same non-thinking templates and assistant masking as
  training. Sequence lengths ranged from 274 to 331 tokens, below the configured
  1,024-token limit; every assistant-prefix boundary matched. See
  [tokenization report](data/tokenization-report.json).
- `./scripts/test.sh`: passed for the current remaining Swift suites. The core
  run reports 258 tests; see `docs/VERIFICATION.md` for the separately documented
  user-requested regression-test removals. The generator changes no Swift code.
- `./scripts/build.sh`: Debug app build passed.

The expanded corpus is original template/word-bank data, with no external
corpus, private archive or model download. Existing adapters were preserved;
no model training or model-quality evaluation was performed for this expansion.
These checks establish data/format consistency, not independently reviewed
natural-language quality or production input-method coverage.

## Initial setup (historical)

- `./llm/setup.sh`: passed on native Apple Silicon macOS, Python 3.12.9.
- MLX 0.32.4 / MLX LM 0.32.2 / Transformers 5.20.2 installed locally;
  `experiment.py doctor` confirmed Metal execution without model weights.
- `python3 -m unittest discover -s llm/tests -v`: 16 tests passed.
- `python3 llm/prepare.py --check`: passed; 67/11/18 train/valid/test records.
- `llm/tests/smoke_mlx.py`: temporary tiny random Qwen3.5 architecture and
  synthetic tokenizer/data checked four-bit conversion, an actual QLoRA
  optimizer update (nonzero LoRA B weights), adapter reload, bounded generation
  and aggregate evaluation. This is not a downloaded 0.8B model test.
- `./scripts/build.sh`: Debug app build passed.
- `./scripts/test.sh`: failed with 23 reported issues across 268 tests in
  36 suites. Failures concern existing Chinese segmentation, spelling/token
  ranking, prefix and automatic-confirmation expectations. No Swift code,
  dictionary, package or Xcode configuration changed in this task. The root
  README already records unresolved migration regressions; they were not
  repaired as part of the offline LLM setup.

Initial sandboxed Swift checks could not access compiler/SwiftPM caches;
the results above are from reruns with normal toolchain cache access.
Build products were not installed or launched, no input source was changed,
and no model or third-party text corpus was downloaded.

That initial setup excluded full Qwen3.5-0.8B loading/conversion/training,
candidate quality, full-size memory/latency, energy use, live SI integration
and host compatibility. Its original 96 examples were smoke fixtures. Later
local diagnostics loaded the user's BF16/four-bit snapshots and existing
four-iteration adapter, but their spelling conversions were incorrect. Neither
those diagnostics nor the expanded synthetic corpus establish model quality.
