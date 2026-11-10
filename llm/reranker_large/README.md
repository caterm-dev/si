# Large candidate reranker

This model family is reserved for candidate scoring after a typing pause and
for measuring the quality/cost tradeoff against the
[small reranker](../reranker_small/README.md). It will score decoder-supplied
candidates; the [Pinyin-to-text model](../pinyin_to_text/README.md) remains a
separate model family.

Use the shared [120-query ranking dataset](../../eval/README.md) for future
candidate experiments. It replaces the old frozen-pool suite and root model
adapters. Generate current engine candidates, keep unreachable targets in the
denominator, and record code/dictionary/model identities. Do not train or tune
against its answers. Any future model adapter and corpus-overlap audit must be
implemented explicitly; no large-model adapter currently exists.

Training code, an approved model configuration and trained weights have not yet
been created. No pause-time scheduling, latency or ranking-quality claim is
implemented by this directory.

Keep this model's future configs, preparation/training/inference code, `runs/`,
`reports/` and exports here. Large generated datasets and weights stay outside
Git. Source corpora and provenance remain in
[corpus/](../../corpus/README.md). The Python environment and pinned dependency
list remain shared at `llm/.venv` and `llm/requirements.txt`.
