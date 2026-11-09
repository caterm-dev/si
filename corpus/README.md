# Offline corpus preparation

Chinese corpus preparation is an explicit, offline stage. Raw source files stay
unchanged. The current command is `prepare_raw_text.py`; the retired Han-fragment
preparation command has been removed. Shared archive readers live in `readers.py`.

## Sources

`--source all` selects the six pinned archives from `chinese/sources.lock.json`
and two explicit local collections:

| Source | Local input and selection |
| --- | --- |
| `lccc` | Pinned LCCC-base training archive; original turns, with artificial Han-token spaces restored. |
| `mc4` | Pinned Chinese training shard 0 of 1,024; full JSON text without the old Han-ratio filter. |
| `kubernetes`, `tensorflow`, `mdn` | Pinned selected Chinese documentation trees; prose extraction removes code and markup. |
| `wikipedia` | Pinned complete current-article archive; namespace 0, nonredirect current wikitext, with titles. |
| `si` | Recursively sorted `chinese/raw/si/**/*.txt`; blank lines delimit conversations. The local `synthetic-dialogues-v1` collection is AI-authored synthetic dialogue, not actual chat transcripts. |
| `dialogue` | `chinese/raw/dialogue/download-manifest.json`, or the existing `dialogue-20261104` directory when `dialogue` is absent. |

The local dialogue manifest describes LCCC-base JSONL/gzip, KdConv JSON,
CrossWOZ JSON/ZIP and OASST1 Parquet. Only utterance text enters `text.txt`.
Dataset, original split, conversation/turn identity and available role/parent
information remain in `documents.jsonl`. OASST1 retains Chinese-language
messages (`zh`, `zh-cn`, `zh-tw`, `zh-hans`, `zh-hant`), without quality filtering;
sibling replies are never fabricated into a linear transcript. The collection's
LCCC archive overlaps the separate `lccc` source; preparation deliberately does
not deduplicate this overlap or assign new training/evaluation splits.

## Environment

Run from the repository root with Python 3.12+:

```sh
python3 -m venv corpus/.venv
corpus/.venv/bin/python -m pip install -r corpus/requirements.txt
# Existing repository-pinned Parquet dependency, needed for dialogue/OASST1:
corpus/.venv/bin/python -m pip install -r corpus/english/requirements.txt
```

OpenCC's hash-pinned `opencc-python-reimplemented==0.1.7` supplies `t2s`.
PyArrow uses the same pin as the existing English dialogue reader. No model,
dictionary or corpus is downloaded by preparation.

## Download, prepare and verify

The six public archive sources can be acquired explicitly:

```sh
python3 corpus/fetch.py all
python3 corpus/fetch.py all --check
# Resolve and acquire a newer complete official Wikipedia dump only when requested:
python3 corpus/fetch.py wikipedia --latest
```

The two local collections must already exist; this command does not acquire
them or infer permission to redistribute their contents.

```sh
corpus/.venv/bin/python corpus/prepare_raw_text.py --source si
corpus/.venv/bin/python corpus/prepare_raw_text.py --source dialogue
corpus/.venv/bin/python corpus/prepare_raw_text.py --source all
# Select another raw root or a fresh output version explicitly:
corpus/.venv/bin/python corpus/prepare_raw_text.py --source si \
  --raw-root /path/to/raw --output /path/to/prepared
```

Default output: `chinese/prepared/raw-text-v2/{source}/`. Each source contains:

- `text.txt`: UTF-8/LF extracted text, converted to Simplified Chinese.
- `documents.jsonl`: origins and exact output line ranges for each extracted
  document, SI conversation or dataset utterance/message.
- `manifest.json`: input hashes, code hashes, OpenCC version/config, counts and
  output checksums. Dialogue also retains the Parquet reader version.
- `attribution/` for dialogue: copied download manifest, acquisition records,
  licenses and metadata, covered by output checksums.

Preparation verifies archive checksums and every declared dialogue data/license
file before reading. SI inputs receive a deterministic file inventory with
sizes and SHA-256 hashes. Local inventories are checked again before publishing,
so edits or additions during processing cannot publish a stale snapshot.
Each source is staged and published only on success. Existing complete outputs
are reused only when input, code, normalization and output hashes still match;
otherwise choose a fresh output directory. Existing bundles are not overwritten.

## Text contract

OpenCC `t2s` applies only to extracted text, not original files, file names,
identifiers, origins or license documents. Output normalizes CRLF/CR to LF and
removes invalid surrogate code points. Numbers, English word spaces, punctuation,
short text, long lines and repeated occurrences remain. SI conversation
separators remain blank lines. There is no Han-only cutting, four-character
minimum, 96-character truncation, character cap, deduplication or tokenization.
Markdown/Wikipedia readers still remove code, templates, tables and references;
removed or never-captured prose is not reconstructed.

The former fragment bundles were deleted on November 5, 2026. Their measured
snapshots (`chinese/snapshot.json`, `chinese/wikipedia-20261001.snapshot.json`)
remain historical provenance. `check.py` verifies that historical fragment
format, not the current complete-text format. The old `prepared/raw-text-v1` directory was deleted at the user's request on
November 8, 2026; current preparation uses `raw-text-v2`. The
`kenlm-raw-v1` / `kenlm-words-v2` generated outputs remain frozen older
artifacts and have not been overwritten or retrained.

## Downstream tools

The [KenLM data record](KENLM_DATA.md) describes the frozen six-source runs.
`prepare_kenlm_raw.py` still defaults to the now-removed `raw-text-v1` input
and six pinned sources. The new eight-source, Simplified extraction is not silently merged into
those runs. Selecting a new training corpus and adapting its tokenization input
are separate explicit steps.

The [unigram tokenizer](UNIGRAM_TOKENIZER.md), historical
[HanLP word review](HANLP_WORDS.md), [English conversation collection](english/README.md)
and [whole-document reranker](../llm/reranker_small/README.md) remain separate.
The reranker shares `readers.py` without adopting this command's new source
selection or output contract. Reading-table export remains:

```sh
corpus/.venv/bin/python corpus/pinyin/build.py --output corpus/pinyin/generated/lexical-v1
```

## Validation and data boundaries

```sh
corpus/.venv/bin/python -m unittest discover -s corpus/tests -v
./scripts/test.sh
./scripts/build.sh
```

Synthetic regressions cover simplification, punctuation/English/numbers,
conversation boundaries and repeated turns, all four dialogue formats,
Chinese-message selection and original parent edges, attribution, checksum
rejection, source changes during extraction, output reuse and rollback.
See [the verification guide](../docs/TESTING.md).

Raw and prepared corpora remain local and ignored by Git. Retain source notices
and review [Chinese data terms](chinese/NOTICE.md) before redistribution. Data
licenses remain separate from the GPLv3 software license. Preparation does not
read private application archives or clipboard data, start training, install SI,
change runtime vocabulary or upload data.
