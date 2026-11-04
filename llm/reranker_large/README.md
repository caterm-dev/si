# Large candidate reranker

This model family is reserved for candidate scoring after a typing pause and
for measuring the quality/cost tradeoff against the
[small reranker](../reranker_small/README.md). It will score decoder-supplied
candidates; the [Pinyin-to-text model](../pinyin_to_text/README.md) remains a
separate model family.

Use the shared [ranking evaluation suite](../../eval/ranking/README.md) and
[prediction/scoring protocol](../../eval/README.md) used by the small model.
Export blind requests with `python3 -m eval export --task ranking --split dev`,
supplying a fresh `--output` path. Return a full candidate-index permutation for
each case and score it with `python3 -m eval score`. Do not build a separate
large-only test set or train on these evaluation labels. A different training
corpus needs its own overlap audit; the small model's audit does not cover it.

Training code, an approved model configuration and trained weights have not yet
been created. No pause-time scheduling, latency or ranking-quality claim is
implemented by this directory.

Keep this model's future configs, preparation/training/inference code, `runs/`,
`reports/` and exports here. Large generated datasets and weights stay outside
Git. Source corpora and provenance remain in
[corpus/](../../corpus/README.md). The Python environment and pinned dependency
list remain shared at `llm/.venv` and `llm/requirements.txt`.
