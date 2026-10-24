# Dependency and model provenance

This is an optional Python experiment. No runtime or weights are bundled with
SI.app. The user explicitly selected Qwen3.5-0.8B for local training; no
third-party text corpus was introduced.

| Component | Initial version | Upstream | License / handling |
| --- | --- | --- | --- |
| Qwen3.5-0.8B | User-selected local snapshot; record exact revision when downloading | [Qwen](https://huggingface.co/Qwen/Qwen3.5-0.8B) | Apache-2.0; no weights redistributed; retain upstream license/NOTICE |
| MLX LM | 0.32.2 | [ML Explore](https://github.com/ml-explore/mlx-lm), [PyPI](https://pypi.org/project/mlx-lm/0.32.2/) | MIT; installed, not vendored |
| MLX / MLX Metal | 0.32.4 | [MLX](https://github.com/ml-explore/mlx) | MIT; installed, not vendored |
| Transformers | 5.20.2 | [Hugging Face](https://github.com/huggingface/transformers) | Apache-2.0; installed, not vendored |
| Synthetic seeds and experiment code | Repository revision | This repository | Repository GPLv3; no imported corpus |

`requirements.txt` declares the direct dependency. `requirements.lock.txt` pins
the full installed environment including training/tokenizer/data dependencies.
This is a macOS Apple Silicon / Python 3.12 environment snapshot, not a
cross-platform lock or hash-verified package manifest. On updates, reinstall in
a fresh environment, retain notices, run contract tests and random-model smoke,
then repeat full-size training/inference verification. Imports alone do not
establish architecture training compatibility.

MIT and Apache-2.0 permit redistribution with their notice/license obligations
and are compatible with GPLv3. This repository does not relicense upstream
models or dependencies. Future model bundling requires an exact revision,
training-data permissions, notices and distribution plan. Private adapters may
retain training material and belong outside source control.

References checked October 24, 2026:
[MLX fine-tuning](https://github.com/ml-explore/mlx-lm/blob/main/mlx_lm/LORA.md),
[Qwen3.5 implementation](https://github.com/ml-explore/mlx-lm/blob/main/mlx_lm/models/qwen3_5.py).
