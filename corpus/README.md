# Offline corpus preparation

Chinese corpus preparation is an explicit, offline stage. Raw source files stay
unchanged. The current command is `prepare_raw_text.py`; the retired Han-fragment
preparation command has been removed. Shared archive readers live in `readers.py`.

## Sources

`--source all` selects the six pinned archives from `chinese/sources.lock.json`,
the SI and dialogue collections, and Chinese Chatbot Corpus when its local
directory is present.

| Source | Local input and selection |
| --- | --- |
| `lccc` | Pinned LCCC-base training archive; original turns, with artificial Han-token spaces restored. |
| `mc4` | Pinned Chinese training shard 0 of 1,024; full JSON text without the old Han-ratio filter. |
| `kubernetes`, `tensorflow`, `mdn` | Pinned selected Chinese documentation trees; prose extraction removes code and markup. |
| `wikipedia` | Pinned complete current-article archive; namespace 0, nonredirect current wikitext, with titles. |
| `si` | Recursively sorted `chinese/raw/si/**/*.txt`; blank lines delimit conversations. The local `synthetic-dialogues-v1` collection is AI-authored synthetic dialogue, not actual chat transcripts. |
| `dialogue` | `chinese/raw/dialogue/download-manifest.json`, or the existing `dialogue-20261104` directory when `dialogue` is absent. |
| `chinese-chatbot-corpus` | Extracted `raw_chat_corpus` files from [codemayq's collection](chinese/metadata/chinese-chatbot-corpus.md). |

Dialogue preparation reads KdConv JSON, CrossWOZ JSON/ZIP and OASST1
Parquet from the local manifest. Only utterance text enters `text.txt`.
Dataset, original split, conversation/turn identity and available role/parent
information remain in `documents.jsonl`. OASST1 retains Chinese-language
messages (`zh`, `zh-cn`, `zh-tw`, `zh-hans`, `zh-hant`), without quality filtering;
sibling replies retain their parent links. The dialogue extractor skips the
manifest’s LCCC-base entry because the pinned `lccc` source handles that archive.
Original source splits are preserved.

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

Place the local collections under `chinese/raw/` before preparing them. For
Chinese Chatbot Corpus, use the Google Drive or Aliyun link in the
[upstream README](https://github.com/codemayq/chinese-chatbot-corpus#使用方法).
Place the contents of the downloaded `raw_chat_corpus` directory directly in
`corpus/chinese/raw/chinese-chatbot-corpus/`, so a source directory such as
`douban-multiturn-100w/` is its immediate child. Partial downloads are accepted
and the manifest lists missing subcorpora and Douban splits. When both PTT
releases are present, the importer selects v2, which extends v1. After adding
files to an existing local collection, use `--output` with a fresh directory
to prepare the expanded collection.

```sh
corpus/.venv/bin/python corpus/prepare_raw_text.py --source si
corpus/.venv/bin/python corpus/prepare_raw_text.py --source dialogue
corpus/.venv/bin/python corpus/prepare_raw_text.py --source chinese-chatbot-corpus
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
- `attribution/` for dialogue and Chinese Chatbot Corpus: source notices and
  available local acquisition and license documents, covered by output checksums.

To prepare only the three local collections in one command, run:

```sh
corpus/.venv/bin/python corpus/prepare_si_raw_text.py
```

The script reads `corpus/chinese/raw/dialogue/`, `chinese-chatbot-corpus/` and
`si/`. If `chinese-chatbot-corpus/` is absent, it reads `chinese-corpus/`.
It writes the same bundle format under `corpus/chinese/prepared/si-corpus/`, with
`dialogue/`, `chinese-corpus/` and `si/` subdirectories. Use `--raw-root`
to point at a different collection root and `--output` to create a fresh
version after changing the raw files.

Preparation verifies archive checksums and every declared dialogue data/license
file before reading. SI inputs receive a deterministic file inventory with
sizes and SHA-256 hashes, as do Chinese Chatbot Corpus inputs. Local inventories
are checked again before publishing, so edits or additions during processing
cannot publish a stale snapshot.
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
Chinese Chatbot Corpus writes individual turns and records their source path,
conversation, turn and upstream split when available. It excludes Douban rows
with negative response labels and PTT missing-data placeholders. Subtitle
segmentation slashes are removed. Weibo posts and replies must have equal
record counts. The manifest counts documents per subcorpus and lines repaired
with Unicode replacement characters after invalid UTF-8.
Markdown/Wikipedia readers still remove code, templates, tables and references;
removed or never-captured prose is not reconstructed.

The older Han-fragment snapshots document prior extraction runs.
`check.py` applies to that fragment format. For current full-text bundles,
rerun preparation with the original input and output paths to verify a
completed bundle.

## Downstream tools

The [15.6M student](../llm/reranker_large/README.md#prepare-existing-raw-text-v2-snapshots)
has an explicit `llm/reranker_large/scripts/prepare-data.sh` stage that reads
existing `raw-text-v2` snapshots and retained source notices directly. It
verifies hashes/ranges, groups and samples the selected Chinese sources,
then freezes a train-only 8K vocabulary and 64-token LM windows. It never
re-extracts raw archives or starts training. Defaults and actual token-share
reports are documented in the student guide.

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
conversation boundaries and repeated turns, the selected dialogue formats and the separate LCCC source,
Chinese-message selection and original parent edges, attribution, checksum
rejection, source changes during extraction, output reuse and rollback.
See [the verification guide](../docs/TESTING.md).

Raw and prepared corpora remain local and ignored by Git. Retain source notices
and review [Chinese data terms](chinese/NOTICE.md) before redistribution. Data
licenses remain separate from the GPLv3 software license. Preparation does not
read private application archives or clipboard data, start training, install SI,
change runtime vocabulary or upload data.
