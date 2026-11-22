# Small character scorer

This directory contains the FP32 Rust inference export of the
7,419,392-parameter `small-character-v1` model at step 30,000.
It has four width-256 Transformer blocks, four attention heads and a
256-token context. It scores supplied candidates in offline evaluations and
is bundled with macOS SI for optional, bounded Local model ranking.
[Runtime policy](../../docs/ranking-architecture.md#local-model-ranking)

| File | Contents |
| --- | --- |
| `model.json` | Architecture, tokenizer characters, tensor shapes and checkpoint identity |
| `weights.f32` | 29,677,568 bytes of little-endian FP32 weights |
| `manifest.json` | Dataset identity, checkpoint identity, source declarations and file checksums |
| `NOTICE.md`, `source-lock.json`, `licenses/`, `metadata/` | Selected training-source notices, pinned revisions and attribution |

The model and weights were moved byte-for-byte from
`.build/si-neural/reranker/`. The matching training checkpoint is
`llm/reranker_small/runs/small-character-v1/best.pt`, identified by SHA-256
`41692f0980708e6f0e16bd54e3d38c59a0475be8a3310500a977474625e1eeb4`.
The source documents retain their own terms, including ShareAlike conditions.
The source notice and manifest record the applicable declarations.

Build the standalone scorer and submit a synthetic candidate pool.

```sh
cargo build --release --locked -p si-neural
printf '%s\n' '{"context":"今天下午，","candidates":["开会","开慧"]}' |
  target/release/si-neural rank Data/RerankerSmall
```

See the [model guide](../../llm/reranker_small/README.md) for training and
the [conversion evaluation guide](../../eval/README.md) for fixed-pool scoring.
