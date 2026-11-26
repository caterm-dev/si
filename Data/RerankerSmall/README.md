# Small character scorer

This directory contains the FP32 Rust inference export of the
7,419,392-parameter small character model. The selected checkpoint is
**small-chat-unused-v3, step 11,000**, from its first 20-million-target stage.
It retains four width-256 Transformer blocks, four attention heads and a
256-token context. macOS SI bundles these files for on-device Local model
ranking, enabled by default and configurable under Typing.
[Runtime policy](../../docs/ranking-architecture.md#local-model-ranking)

| File | Contents |
| --- | --- |
| model.json | Architecture, frozen tokenizer characters, tensor shapes and checkpoint identity |
| weights.f32 | 29,677,568 bytes of little-endian FP32 weights |
| manifest.json | Selected checkpoint, full training lineage, evaluation identity and file checksums |
| NOTICE.md, source-lock.json, licenses/, metadata/ | Current and inherited training-source notices, pins and attribution |

## Selected checkpoint

The selected file is
llm/reranker_small/runs/small-chat-unused-v3/snapshots/stage-1-20001617-tokens/best.pt,
identified by SHA-256
67e15a25db10a8c7ad8f972bb60813a35651fe0dd3616dc6ab594ba07422f937.
It has seen 19,882,752 target tokens in this continuation; the stage stopped
at 20,001,617. The live run subsequently continued, so its mutable best.pt
must not be used to recreate this selected bundle.

The checkpoint inherits chat-v2 at step 7,810, which inherits the original
v1 checkpoint at step 30,000. The tokenizer is shared throughout. Source
notices for both ancestors are retained under metadata/lineage/; root
notices describe the current continuation. The copied documents retain
their own terms, including unresolved source declarations and ShareAlike
conditions. No blanket model-weight license is assigned.

## Validation and regeneration

On the reviewed frozen candidate suites, the selected export placed
370/531 context-free references and 314/458 contextual references first.
Both contextual references were first in 87/229 contrast pairs. These are
synthetic supplied-candidate measurements, not end-to-end input-method
accuracy, representative typing coverage or host latency.

Regenerate the two inference files into a fresh temporary directory:

```sh
llm/.venv/bin/python -m llm.export_rust reranker \
  --checkpoint llm/reranker_small/runs/small-chat-unused-v3/snapshots/stage-1-20001617-tokens/best.pt \
  --output .build/reranker-stage-1-export
```

Keep the selected checkpoint identity, three-stage lineage and verified
per-stage attribution together when preparing a replacement resource manifest.
The resource manifest hashes every packaged file except itself.

The app packaging script copies this directory into
SI.app/Contents/Resources/SIEngine/RerankerSmall/. Rebuild the app to
package a changed bundle; these source files do not update an installed app.

## Integration checks and known difference

The packaged files reproduce the selected checkpoint's complete fixed-pool
ranking report exactly. Resource-manifest verification and seven Rust/PyTorch
scoring parity cases pass; maximum absolute score difference is 0.000515.

Three of the four focused engine reranker tests pass. The existing
small_reranker_preserves_model_gaps_across_large_statistical_gaps test fails
for its synthetic word-frequency contrast. The scorer still prefers
原始拼写 to 元是拼写, but its mean model gap is 2.350 bits versus the
previous v1 model's 2.582 bits. At the configured 0.8 reward weight, the
new 1.880-bit advantage cannot overcome the fixture's 1.963-bit frequency
gap (390 versus 100 occurrences). The original regression expectation and
ranking configuration are retained. This model-dependent integration
difference remains unresolved. Native host-app checks were not run for
this resource replacement.

Build the standalone scorer and submit a synthetic candidate pool:

```sh
cargo build --release --locked -p si-neural
printf '%s\n' '{"context":"今天下午，","candidates":["开会","开慧"]}' |
  target/release/si-neural rank Data/RerankerSmall
```

See the [model guide](../../llm/reranker_small/README.md) for training and
the [conversion evaluation guide](../../eval/README.md) for fixed-pool scoring.
