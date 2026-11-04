# SI model workspace

Each model family owns its configurations, training code, data preparation,
checkpoints, reports and exports. Native AI ranking and app model loading have been removed pending redesign. Offline models are not loaded
by the input method.

All model families and non-model algorithms share the root
[evaluation registry](../eval/README.md): fixed ranking, correction and
Pinyin-to-Hanzi suites, common predictions/scoring and guarded comparisons.
Public evaluation data is owned there; this workspace owns training and
model-specific token-loss evaluation. Existing small-model benchmark data paths
are compatibility links to the same frozen root files.

| Directory | Purpose | Current status |
| --- | --- | --- |
| [reranker_small/](reranker_small/README.md) | Small candidate language-model scorer. | Offline 7.4M baseline training, scoring/export and a 1,230-case constructed ranking challenge are implemented; native AI ranking is removed pending redesign; independent quality review remains pending. |
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
