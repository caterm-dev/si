# Local small-reranker artifacts

The native comparison uses `SmallReranker.mlmodelc`, `tokenizer.json` and
`runtime.json`, staged explicitly by `llm.reranker_small.coreml_export`.
Generated weights, metadata and copied training-source notices remain ignored.
Ordinary builds never download or train a model. Without staged artifacts the
comparison reports that AI is unavailable and ordinary conversion still works.
