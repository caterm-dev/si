# Synthetic data provenance, format and retention

## Origin and size

`seeds.jsonl` contains exactly **10,000 records / 10,000 expanded examples**,
created for this repository on October 24, 2026 under the repository GPLv3
license: **8,000 train / 1,000 validation / 1,000 test**. All new records use
`variants=[]`, so a physical JSONL line is one training/evaluation example.

The original 63 seed records / 96 examples are preserved in `bootstrap.jsonl`.
`../generate_data.py` expands them into explicit rows and adds 9,904 synthetic
examples using **226 authored lexical/phrase entries**, **49 Chinese sentence
frames**, and additional authored English, mixed-text, identifier, ambiguity
and prediction families. All readings and candidate labels come from those
explicit sources, with deterministic slot combinations and spelling edits.
There are no model-generated judgments, corpus-derived frequency rankings or
claims of 10,000 independently authored utterances.

No external corpus, system/SI dictionary, learning/history archive, personal
phrase, host document, clipboard, message or typing log was read or copied.
No third-party dataset or model weights are redistributed. Runtime generation
uses only Python's standard library, without network requests or SI decoding.

## Composition

| Category | Records |
| --- | ---: |
| Chinese conversion | 3,472 |
| Typo/correction examples | 2,010 |
| Incomplete spelling | 993 |
| Syllable initials | 400 |
| Chinese/English mixed input | 799 |
| English segmentation/correction | 694 |
| Correct English, identifiers and instruction-like text preservation | 705 |
| Chinese/English suffix prediction | 651 |
| Ambiguous readings and contextual choices | 156 |
| ü / v / u: spellings | 69 |
| All languages disabled | 40 |
| Original empty/disabled/language/separator/context/literal cases | 11 |

Generated Chinese spelling errors apply one deletion, insertion, adjacent transposition
or neighboring-key substitution to the annotated full spelling. Generated incomplete
examples remove one or two terminal letters, and initials use the authored
syllable boundaries. English identifiers in mixed examples are preserved byte
for byte. Prediction contexts end at explicit authored boundaries and labels
contain only newly suggested suffixes, including intentional leading spaces
for English. Instruction-like strings are labeled as ordinary literal text,
not instructions to execute. Their presence does not establish injection
resistance; that needs separate adversarial evaluation.

## Split isolation and limits

Source families are assigned to a split **before** generating their spelling,
slot, language-profile or task variants. Exact requests are unique, and identical
complete conversion language/text targets cannot occur in different splits.
The report lists group membership, category counts, distinct target counts,
cross-split overlap checks and source/generator hashes. Common component words
are shared across splits. The held-out frames test synthetic generalization;
they are visible development fixtures, not independent natural-language
quality evidence. Template combinations are less diverse than independently
written sentences, and some permitted combinations may be uncommon.

One original leak was repaired: `partial-world` (`shij` -> `世界` / `时间`)
was in training while `ambiguous-shijie` (`shijie` -> `世界` / `时节` / `视界`)
was in validation. The partial case now belongs to the same validation group.
Original requests and candidate labels are retained. The bootstrap snapshot
remains unchanged as historical provenance. No evaluated failure was moved
into training to improve a measured score.

Candidate lists are authored acceptable alternatives in an intended order,
not exhaustive judgments or empirical frequencies. Initials, partial spellings
and edited strings can have other valid readings; an exact-match miss is not
automatically a linguistic error. Structural/phonetic consistency checks and
representative inspection do not constitute independent review of every label.

## Reproduce and extend

From the repository root:

```sh
python3 llm/generate_data.py
python3 llm/generate_data.py --check
python3 llm/prepare.py
python3 llm/prepare.py --check
python3 -m unittest discover -s llm/tests -v
```

Generation validates the complete replacement before writing seeds/report.
Edit authored banks/frames or bootstrap data to retain additions across future
regeneration. Hand-editing `seeds.jsonl` and preparing it also works, but the
generator's `--check` will report a difference. `dataset-report.json` records
the generated source hashes. `tokenization-report.json` records the later
local Qwen tokenizer sequence-length and assistant-boundary checks; it contains
no weights, requests or candidate text. It applies only to the recorded source
hash/model configuration and is not a training or model-quality result.

Each seed contains `id`, `group`, `split`, `category`, `request`, `variants`
and `candidates`. Variants inherit request options and the candidate list;
only add a variant when that target remains appropriate. `task=convert`
labels complete composition output. `task=predict` labels only new suffixes
after explicit context + input; empty-input prediction is an offline task,
not a change to SI's empty-composition behavior. Language identifiers are
`en`, `zh-Hans`, or `mixed` when both are enabled. The application adds the
separate `verbatim` identity; no training label uses it.

Preparation exports MLX chat JSONL, matching evaluation cases and a SHA-256
manifest under ignored `data/prepared/`. It uses the same system prompt as
inference. Regenerate prepared files after changing source data or that prompt;
training rejects stale files. This expansion does not change the model base,
chat protocol or loss configuration, and does not retrain existing adapters.

## Private material

Keep separately authorized private corpora under ignored `data/private/`, with
their own origin, license, consent, retention and deletion notes. Supply a seed
file explicitly using `prepare.py --source ... --output ...` and matching
`train --source ... --data ...`. These scripts do not discover or ingest SI
archives; existing vocabulary/history consent does not authorize training.
Private corpora, adapters and reports remain until manually deleted. Deleting
examples does not erase them from existing adapters: delete affected runs and
retrain when removal is required. No automatic upload, collection or expiry runs.
