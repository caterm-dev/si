# Retired frozen-pool challenge

The old `chinese-v1` dataset, authored source files and compatibility links were
removed at the user's request on November 9, 2026. The replacement is the newly
authored [5,000-query ranking dataset](../../../eval/README.md). It has no frozen
pools, old labels or model-specific adapter.

The builder/evaluator utility functions remain for legacy temporary-fixture tests
and explicit old-format experiments. Their default dataset/source paths now fail
with replacement guidance; they cannot evaluate the new query-only data directly.
Standalone candidate scoring and the small three-row workflow example remain
model-specific tools, separate from the new ranking test set.
