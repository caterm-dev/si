# Ranking evaluation moved

The canonical dataset, authored sources and full construction/evaluation guide
now live under [eval/ranking/](../../../eval/ranking/README.md).
Use the [shared evaluation protocol](../../../eval/README.md) to compare small,
large or algorithmic predictors on the same frozen cases.

Compatibility links retain `chinese-v1/`, `lexical.tsv` and `additional.jsonl`,
so the existing builder, tests and `scripts/evaluate_suite.sh` still read the
same bytes. `example.jsonl` is only a three-case workflow fixture.
The historical model-specific evaluator/report format remains available; it is
not the unified prediction/report protocol.
