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

## Integration checks

The packaged files reproduce the selected checkpoint's complete fixed-pool
ranking report exactly. Resource-manifest verification and seven Rust/PyTorch
absolute-scoring parity cases passed for the resource replacement; those
historical measurements do not evaluate the current conditional-probability policy.

Production Local model ranking now uses whole-candidate conditional sequence
log probabilities, pool-relative clipping at eight bits
and a default weight of 0.8. Empty context compares summed BOS log probabilities
without output-length normalization, relative to the highest pool score,
with the same eight-bit clipping before weighting.
After successful scoring, ordinary whole candidates outside the pool receive
its lowest adjustment; identical scored text reuses the actual value. Completions
and corrections use that fallback without additional inference. Prefixes,
literals, personal phrases and verbatim paths remain exempt.
The unconditional baseline has a bounded in-memory exact-string LRU.
See the [runtime policy](../../docs/ranking-architecture.md#local-model-ranking)
and [integration checks](../../docs/TESTING.md#local-model-ranking-in-a-host).

The former absolute-score regression for `原始拼写` versus `元是拼写`
recorded a 2.350-bit mean-model gap for this checkpoint versus v1's 2.582 bits.
That difference belonged to the old 0.8-weight absolute-score policy. It is
not a model-weight fix or evidence for the conditional-probability policy; current
tests verify conditional probabilities, BOS sequence-score differences and bounded
penalties, including rare candidates whose lift would invert their probability order.
Native host behavior remains unverified for the new runtime policy.

Build the standalone scorer and submit a synthetic candidate pool:

```sh
cargo build --release --locked -p si-neural
printf '%s\n' '{"context":"今天下午，","candidates":["开会","开慧"]}' |
  target/release/si-neural rank Data/RerankerSmall
```

See the [model guide](../../llm/reranker_small/README.md) for training and
the [conversion evaluation guide](../../eval/README.md) for fixed-pool scoring.
