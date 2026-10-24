# Offline LLM input-method experiment

Fine-tune local Qwen3.5-0.8B to generate ordered candidates directly from raw
spelling. Conversion, typo correction and ordering share one output contract;
suffix prediction is another task using the same model. This experiment does
not call SI's dictionary/lattice decoder or change the Swift app. It captures
no typing and reads no host documents or private SI archives.

Full-composition generation is supported here. Source-aligned prefix commits,
live asynchronous delivery, multilingual coverage guarantees and host
integration remain future work. Setup does not establish accuracy or latency.

## Setup and local model

Use native Apple Silicon macOS and Python 3.11+ (3.12 recommended). From the
repository root:

```sh
./llm/setup.sh
```

Setup creates `llm/.venv`, installs the pinned environment, prepares synthetic
data, runs Python tests and checks Metal. Package installation needs internet;
**no model or external corpus is downloaded**. It uses existing Python and
`uv` when available, otherwise `venv`/`pip`. Override Python with
`PYTHON=/absolute/path/to/python3 ./llm/setup.sh`. The pinned MLX backend may
require newer macOS than SI itself; installation and `doctor` must pass on the
actual machine. No system memory settings are changed.

Download the complete [Qwen/Qwen3.5-0.8B snapshot](https://huggingface.co/Qwen/Qwen3.5-0.8B)
yourself into `llm/models/Qwen3.5-0.8B/`: configuration, tokenizer/chat template,
Safetensors weights, license and notices. Other complete local MLX snapshots
also work. **GGUF/Ollama files cannot be trained by this setup.** Model IDs are
rejected; model operations force Hugging Face offline mode and disable remote
code execution and telemetry. See [model files](models/README.md).

For a four-bit MLX copy:

```sh
llm/.venv/bin/python llm/experiment.py convert \
  --model llm/models/Qwen3.5-0.8B \
  --output llm/models/Qwen3.5-0.8B-4bit
```

Conversion requires a new destination. MLX LM loads the language model; the
task never uses images. Use the **same base snapshot and quantization** for
training, adapter reload and comparisons. An existing compatible MLX four-bit
snapshot needs no conversion; BF16 local weights use ordinary LoRA instead.

## Data and training

`data/seeds.jsonl` contains **10,000 synthetic records**: 8,000 training,
1,000 validation and 1,000 test examples. Topics include mistakes, ambiguous
Pinyin, short words/phrases, partial input, initials, ü/u: aliases, English,
mixed text, identifiers, language filtering and suffix prediction. The corpus
uses original authored readings, word banks and templates, not an external
dictionary or harvested user text. It is development training data, not evidence
of real-world accuracy. See [provenance and format](data/PROVENANCE.md), the
[dataset report](data/dataset-report.json) and the [generator](generate_data.py).

```sh
python3 llm/generate_data.py --check
python3 llm/prepare.py
python3 llm/prepare.py --check
python3 -m unittest discover -s llm/tests -v

llm/.venv/bin/python llm/experiment.py train \
  --model llm/models/Qwen3.5-0.8B-4bit \
  --output llm/runs/smoke --iters 4

llm/.venv/bin/python llm/experiment.py train \
  --model llm/models/Qwen3.5-0.8B-4bit \
  --output llm/runs/expanded-v1 --iters 8000
```

Preparation exports MLX chat JSONL, matching evaluation cases and a SHA-256
manifest under ignored `data/prepared/`. Variants inherit their group's split;
duplicate requests and cross-split groups are rejected. The system prompt is
shared with inference. Reprepare after changing source data or the prompt;
training rejects stale prepared files. Keep related source documents, contexts
and variants together when adding real data.

`generate_data.py` deterministically regenerates seeds and their report from
the authored banks/templates plus `data/bootstrap.jsonl`; use `--check` to
verify without writing. The snapshot has one example per line (`variants=[]`).
The original 96 examples are retained, with one pre-existing train/validation
leak repaired; see provenance. Sentence-frame and spelling variants stay
together, and complete conversion targets do not overlap between splits.
Slot vocabulary is shared, so this is a synthetic development evaluation,
not an independent natural-text benchmark. Extend the generator or bootstrap
when retaining handwritten additions across regeneration. Direct seed edits
can still be prepared, but will differ from the generated snapshot.

The expanded training command above processes the 8,000 training examples
once at batch size one (2,000 optimizer updates with accumulation four).
It is a starting experiment, not a validated convergence recommendation;
compare validation candidate quality before extending training. The YAML's
100-iteration default remains a short diagnostic. Existing smoke adapters
remain products of their original data/steps and are not retrained by preparing
new files.

Each training run requires a new output directory. `--dry-run` validates files
and prints the plan without loading weights (local files must still exist).
[Default settings](configs/lora.yaml) adapt the last four layers, batch size
one, four gradient accumulation steps, rank eight and gradient checkpointing.
These are starting parameters, not measured optimal settings or memory limits.
The wrapper calls MLX LM's trainer, masks prompt loss, disables thinking in
both training and inference, and rejects overlong training records or mismatched
assistant-prefix token boundaries before updates. Iterations count minibatches
and must be a multiple of gradient
accumulation; the four-iteration smoke applies one optimizer update. It writes
adapter weights/config and a recipe with dataset hashes.
Training never starts automatically. No fusion is needed to evaluate adapters.

To use separately authorized private seeds:

```sh
python3 llm/prepare.py --source llm/data/private/seeds.jsonl \
  --output llm/data/private/prepared
```

Pass matching `--source llm/data/private/seeds.jsonl` and
`--data llm/data/private/prepared` to training. Existing SI vocabulary/history
consent is not training consent. No automatic corpus import or collection runs.

## Generate candidates

Send one explicit JSON request on stdin. This example is synthetic:

```sh
llm/.venv/bin/python llm/experiment.py infer \
  --model llm/models/Qwen3.5-0.8B-4bit <<'JSON'
{"task":"convert","input":"shijie","languages":["en","zh-Hans"]}
JSON
```

Add `--adapter llm/runs/expanded-v1` to load trained weights. The model returns
`{"candidates":[{"text":"世界","language":"zh-Hans"},...]}`. The wrapper
adds the **exact** original spelling with identity `verbatim`, then returns
`candidates`, `status` and timing data. This is an illustrative shape, not a
measured model result. At most five generated suggestions precede the literal.
Language identities are `en`, `zh-Hans`, or `mixed` when both are enabled.
Same text in different languages remains distinct. Canonical duplicates within
one language are rejected without normalizing output bytes.

Empty conversion input returns nothing. All languages disabled returns only
the original input without loading weights. Invalid/truncated/decorated JSON,
duplicate candidates or disabled labels cause atomic rejection and status
`invalid_response`, with original input still available. Structural validation
does not guarantee meaning or language coverage. Greedy generation fixes the
sampling policy; hardware/version repeatability is unproven. There is a token
limit, no hard time deadline; the result appears after the entire list finishes.

For prediction, explicitly supply context; outputs contain only NEW suffixes:

```sh
llm/.venv/bin/python llm/experiment.py infer \
  --model llm/models/Qwen3.5-0.8B-4bit <<'JSON'
{"task":"predict","input":"","context":"Good","languages":["en"]}
JSON
```

Prediction has no literal candidate. Correct suffix boundaries are learned,
not guaranteed by validation. This offline task does not change SI's
empty-composition behavior. Inference saves no input/raw-response file or chat
history, but prints the requested result to stdout; terminal capture/redirection
can retain it.

## Evaluate and verify

Compare base and adapter on validation during development. Use untouched test
groups only after choosing data/settings. Existing output reports are never
overwritten:

```sh
llm/.venv/bin/python llm/experiment.py evaluate \
  --model llm/models/Qwen3.5-0.8B-4bit \
  --cases llm/data/prepared/valid.cases.jsonl \
  --output llm/runs/base-valid.json

llm/.venv/bin/python llm/experiment.py evaluate \
  --model llm/models/Qwen3.5-0.8B-4bit \
  --adapter llm/runs/expanded-v1 \
  --cases llm/data/prepared/valid.cases.jsonl \
  --output llm/runs/adapter-valid.json

llm/.venv/bin/python llm/experiment.py doctor
llm/.venv/bin/python llm/tests/smoke_mlx.py
```

Evaluation loads once, warms up once and runs sequential requests with fresh
caches. Reports contain aggregate/category top-one/top-five acceptable-match
rates, reciprocal rank, preservation top-one error rate, invalid responses,
literal failures, load time, MLX peak allocation and request latency percentiles.
Matching ANY authored acceptable language/text pair counts as a hit; this does
not judge exact list ordering or exhaustive recall. Empty targets request
abstention. The literal never inflates model quality; bypasses never lower
model latency percentiles. Peak allocation is MLX memory, not process RSS.
First token is **not** first complete candidate. Total time includes formatting,
generation and validation, excludes model load, and is not host-app latency.
No case/context/candidate/raw-response text is written into reports.

The optional Metal smoke uses temporary tiny random Qwen3.5 weights/tokenizer
to check conversion, a QLoRA update, adapter reload and bounded generation. It
downloads nothing and deletes temporary weights on exit. This verifies API
plumbing, not full-size model memory, speed or linguistic quality. Future live
integration also needs cancellation, energy, candidate-churn and host checks.

Models, caches, environments, generated/private data and run artifacts are
ignored by Git. They persist until manually deleted; deleting training data
does not remove it from existing adapters. See [run retention](runs/README.md),
[data handling](data/PROVENANCE.md), [dependencies](DEPENDENCIES.md) and the
[recorded validation](VALIDATION.md).
