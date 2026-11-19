# SI model workspace

Each model family owns its configurations, training code, data preparation,
checkpoints, reports and exports. Native AI ranking and app model loading have been removed pending redesign. Offline models are not loaded
by the input method.

The root [ranking regression dataset](../eval/README.md) holds authored
input/target queries for the Rust engine. Model-specific training,
token-loss evaluation and supplied-candidate scoring live here.

| Directory | Purpose | Current status |
| --- | --- | --- |
| [reranker_small/](reranker_small/README.md) | Small candidate language-model scorer. | Offline 7.4M baseline training and standalone scoring/export remain implemented; native AI ranking is removed pending redesign; independent quality review remains pending. |
| [reranker_large/](reranker_large/README.md) | Candidate scoring after a typing pause, and a larger comparison model. | Reserved; training/inference implementation and weights are not created. |
| [pinyin_to_text/](pinyin_to_text/README.md) | Pinyin/spelling-to-text conversion with the existing encoder-decoder. | Implemented offline framework, retained 19.7M/default and older 0.403B experiments. |

```text
llm/
  reranker_small/       Small LM, document preparation, scripts, tests and ignored training outputs
  reranker_large/       Large candidate reranker
  pinyin_to_text/
    configs/           Model and smoke configurations
    data/              Maintained CSVs and ignored immutable prepared datasets
    csv_data/          Conversion-specific preparation and smoke workflow
    scripts/           Separate setup/data/train/evaluate/infer/export commands
    tests/             Conversion-framework regression coverage
    runs/              Ignored training checkpoints and exports
    reports/           Ignored evaluations and audit reports
    *.py               Conversion model and training/inference implementation
  requirements.txt     Pinned shared Python dependencies
  .venv/               Existing shared environment; ignored and retained in place
  .cache/              Shared package cache; ignored and retained in place
```

Public raw and cleaned text stays in the separate [corpus workspace](../corpus/README.md).
The small reranker's explicit preparation command freezes selected cleaned whole
documents and token arrays in its own ignored dataset directory. No training stage
starts automatically. Models retain actual selected corpus provenance and licenses.
Live personal phrases, learning archives and typing history are not model inputs. A user may explicitly export and voluntarily share history as one ordinary JSONL file; the separate [receiver workflow](../docs/INPUT_HISTORY_EXPORT.md) validates/restores it and prepares private, unsplit, unreviewed CSV candidates. That workflow does not append to current datasets or start training. Review rights/private content, correct labels and grouped split separation before any explicit use.

Git retains model code, scripts, configurations, dependency pins, authored static
training CSVs and frozen benchmark fixtures. Static CSVs are source inputs, not
download caches; some were materialized once and have no regeneration script.
Downloaded/raw inputs, generated data, prepared bundles, environments, caches,
runs, exports and reports are ignored. Existing local copies remain usable after
removal from tracking. Fresh clones recreate prepared bundles with each model's
`scripts/data.sh` after obtaining its documented source inputs; training remains
a separate explicit step. See [the repository data policy](../CONTRIBUTING.md#local-corpus-and-model-artifacts).

## Conversion commands

Use the explicit model directory for new work:

```sh
./llm/pinyin_to_text/scripts/check.sh
./llm/pinyin_to_text/scripts/data.sh
./llm/pinyin_to_text/scripts/run.sh
./llm/pinyin_to_text/scripts/validation.sh
./llm/pinyin_to_text/scripts/infer.sh --input nihao
make -C llm/pinyin_to_text size
```

Every command performs one stage; only setup installs dependencies. See the
[conversion guide](pinyin_to_text/README.md) for presets and independent stages.
`make -C llm <target>` delegates existing conversion targets to `pinyin_to_text`;
`make -C llm help` lists model families and their status.

## Rust inference prototype

`si-neural` runs the Pinyin encoder/decoder and small character scorer from
local FP32 weights. The CLI and library share tokenization, attention and
beam search. macOS uses Accelerate for matrix multiplication. Other targets
use the portable Rust implementation, which is also available on macOS with
the `portable-matmul` Cargo feature. The same runtime powers the optional macOS
ranking build.

From the repository root, export both trusted local checkpoints and build the
standalone executable:

```sh
llm/.venv/bin/python -m llm.export_rust pinyin \
  --checkpoint llm/pinyin_to_text/runs/small-pinyin-lexical-v1/best.pt \
  --output target/si-neural/pinyin
llm/.venv/bin/python -m llm.export_rust reranker \
  --checkpoint llm/reranker_small/runs/small-character-v1/best.pt \
  --output target/si-neural/reranker
cargo build --release --locked -p si-neural
```

Python is used for export and parity checks. The Rust executable reads one JSON
request per line and keeps the model loaded for subsequent requests:

```sh
printf '%s\n' '{"input":"nihao","beam_size":5}' \
  | target/release/si-neural generate target/si-neural/pinyin
printf '%s\n' '{"context":"今天下午，","candidates":["开会","开慧"]}' \
  | target/release/si-neural rank target/si-neural/reranker
```

Generation returns model hypotheses and an exact literal fallback. A contextual
Pinyin bundle accepts up to three caller-supplied `syllable_paths` and optional
`context`; `input` is continuous toneless spelling. Ranking returns one
conditional score per supplied candidate in request order and a sorted index
list. If a candidate exceeds the context limit, scores are null and the original
order is returned. Model files live under ignored `target/`. The manifest records
tensor shapes, tokenizer scalars and checkpoint provenance; `weights.f32` stores
little-endian row-major weights in tensor-name order. Use bundles generated by the
exporter. The prototype caps FP32 weights at 512 MiB. `serde_json` 1.0.151
parses metadata and requests under MIT or Apache-2.0 terms.
Model redistribution requires review of the training-source terms.

Validate with the matching checkpoints:

```sh
llm/.venv/bin/python -m llm.check_rust \
  --binary target/release/si-neural \
  --pinyin-bundle target/si-neural/pinyin \
  --pinyin-checkpoint llm/pinyin_to_text/runs/small-pinyin-lexical-v1/best.pt \
  --reranker-bundle target/si-neural/reranker \
  --reranker-checkpoint llm/reranker_small/runs/small-character-v1/best.pt
```

The first check used the spelling-only checkpoint, the 30,000-step small scorer
and synthetic input on arm64 macOS. Seven generation requests matched PyTorch's
ordered candidates. Six ranking requests matched its order and abstention, with
maximum absolute score error about 0.000361 across 16 scored candidates. The
portable Rust path on arm64 and the x86-64 macOS build under Rosetta also passed
the same fixtures. CLI
round trips over 12 warm repeats had medians of about 40 ms for `fangan` at
beam 8 and 78 ms for a 32-candidate ranking request. These timings include the
JSON transport and exclude training/export. They cover a single machine and
fixture per operation. Linux and Windows still need native build and latency
checks.

## Experimental input ranking

To run the complete local pipeline, first create the two bundles above. Prepare
and train a full v5 run with those same checkpoints using the [offline LambdaRank
workflow](../eval/lambdarank/README.md#merge-neural-candidates-and-scores). Export
the model and verify every prepared feature row against LightGBM:

```sh
.venv/lambdarank/bin/python scripts/lambdarank/export_runtime.py \
  --run eval/lambdarank/runs/neural-v5 \
  --bundle eval/lambdarank/prepared/neural-v5 \
  --binary target/release/si-neural --output target/si-neural/lambdarank.json
SI_EXPERIMENTAL_RANKING=1 ./scripts/build.sh
SI_EXPERIMENTAL_RANKING=1 ./scripts/test.sh --filter CandidatePipelineTests
SI_EXPERIMENTAL_RANKING=1 \
  SI_TEST_ENGINE_RESOURCE_DIRECTORY="$PWD/.build/xcode/Build/Products/Debug/SI.app/Contents/Resources/SIEngine" \
  ./scripts/test.sh --filter CandidatePipelineTests
```

The build flag stages both inference bundles and the trees under
`SI.app/Contents/Resources/SIEngine/Ranking`. The worker checks feature order and
the two checkpoint identities when loading the assets. `SI_RANKING_ASSET_DIRECTORY`
can point at another directory with the same layout. The ordinary build omits
these local model assets. Python is used for training, export and comparison.
The app runs the generator, scorer and trees in Rust.

The existing preview appears first. A background full request combines SI
complete candidates and completions with neural hypotheses, computes the same 61 feature columns
and returns a model score for each eligible row. The spelling-only checkpoint
provides hypotheses on eligible lowercase Pinyin input. The small scorer uses
the preceding field text when available. Generated-only rows require explicit
selection and are excluded from learning. Model-ranked results skip automatic
prefix confirmation. A missing or incompatible bundle falls back to the
ordinary engine. This build is for local development and correctness checks.

## Existing experiments and compatibility

All original conversion code, data, configs, prepared datasets, runs and reports
were moved under `pinyin_to_text/`. For example, an old
`llm/runs/small-pinyin-lexical-v1/best.pt` is now
`llm/pinyin_to_text/runs/small-pinyin-lexical-v1/best.pt`. Update explicit paths
in shell environment overrides and commands. Historical paths recorded inside
immutable manifests, checkpoints and reports remain as originally written;
their bytes, dataset IDs and checkpoint identities are not rewritten.

The model's Python source bytes remain unchanged, preserving its strict code
identity through relocation. Existing resume checks still require matching
data, config, tokenizer, device, threads and PyTorch; a checkpoint already
incompatible before this move remains incompatible. No new formal training is
started as part of this organization.

Two compatibility links remain: `scripts/` points to the conversion scripts,
and `configs/` points to its configs so original module defaults still resolve.
Old imports such as `llm.train` resolve the same relocated source files;
new commands use `llm.pinyin_to_text.*`. These links/imports do not select a
reranker or duplicate its implementation. The shared `.venv` is retained at its
original path so installed interpreter entry points remain valid.
