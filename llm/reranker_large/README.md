# Large candidate reranker

This model family is reserved for candidate scoring after a typing pause and
for measuring the quality/cost tradeoff against the
[small reranker](../reranker_small/README.md). It will score decoder-supplied
candidates; the [Pinyin-to-text model](../pinyin_to_text/README.md) remains a
separate model family.

Training code, an approved model configuration and trained weights have not yet
been created. No pause-time scheduling, latency or ranking-quality claim is
implemented by this directory.

Keep this model's future configs, preparation/training/inference code, `runs/`,
`reports/` and exports here. Large generated datasets and weights stay outside
Git. Source corpora and provenance remain in
[corpus/](../../corpus/README.md). The Python environment and pinned dependency
list remain shared at `llm/.venv` and `llm/requirements.txt`.
