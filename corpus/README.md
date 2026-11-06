# Offline corpus preparation

Chinese is the first supported corpus language. This directory acquires public
text, prepares separate source corpora, and exports explicit lexical readings.
Its organization follows [chinese-ime-lm's corpus tools](https://github.com/metasequoiaime/chinese-ime-lm/tree/154eb5c59a5ad9b0c93a48b05dc7cd143601d18a/corpus).
The implementation is SI-authored and independent of the input method and the
existing `llm/` CSV experiments.

The historical [HanLP word-frequency review](HANLP_WORDS.md) segmented frozen
Chinese bundles locally, preserved per-source counts, and proposed missing
words for manual vocabulary review. It does not train or add a runtime model.

The independent [streaming unigram tokenizer](UNIGRAM_TOKENIZER.md) applies
NFKC/invisible-character cleaning, punctuation sentence splitting and local
dictionary/Viterbi Han segmentation to explicitly selected text files. It
preserves lowercased English, numbers and punctuation in space-separated output,
with bounded multiprocessing and a 100-token sentence limit. It uses only the
Python standard library and leaves earlier corpus bundles and SI vocabulary intact.

The current [raw-derived KenLM workflow](KENLM_DATA.md) reads all six pinned
local raw archives and preserves numbers, English, punctuation, short spans
and repeated occurrences. It uses the same custom unigram tokenizer, keeps
commas/enumeration commas inside sentences and records exact sentence lineage.
The current v2 dictionary reads only flat Chinese word CSVs, excluding
`Data/Vocabulary/chinese/phrase/`; observed corpus counts and explicit
pseudocount-1 smoothing supply unigram probabilities, rather than input-method
ranking weights. Outputs are under `chinese/generated/kenlm-words-v2/`.
The earlier local Han-fragment bundles and their derived token files were
**deleted at the user's request on November 5, 2026**. Historical counts below
remain provenance records; their old local paths are not current training data.

```sh
python3 corpus/prepare_raw_text.py --source all
python3 corpus/build_word_dictionary.py
python3 corpus/prepare_kenlm_raw.py tokenize --workers 4
python3 corpus/prepare_kenlm_raw.py finalize
```

The explicit [KenLM configuration-selection workflow](../README_kenlm_train.md)
uses `kenlm_train.py` to deduplicate exact lines, split stable 1,000-line blocks
with seed 20261105, run all four smoke tests, and compare train-split quantized
trie models on the same heldout file. Tool source pins/notices are retained under
`kenlm/`; generated splits, models and logs remain local. Final combined-data
retraining waits for the user's later configuration choice.

The commands below for `prepare.py` reproduce the historical Han-fragment
contract only. Use the raw workflow above for complete-text KenLM preparation.

The separate [English conversation collection](english/README.md) acquires and
prepares PersonaChat/ConvAI2, BlendedSkillTalk, Topical-Chat, Taskmaster 1/2/3,
ABCD, Schema-Guided Dialogue and an English OASST1 subset. It preserves source
licenses, conversation/turn identity and upstream splits, including explicitly
unassigned data. The [source review](english/SOURCE_REVIEW.md) records the
selection rationale and deferred alternatives. The Chinese commands and
Han-fragment contract below remain separate from English dialogue preparation.

| Path | Contents |
| --- | --- |
| `chinese/sources.lock.json` | Reviewed source revisions, URLs, sizes, hashes and data terms. |
| `chinese/licenses/`, `chinese/NOTICE.md` | Full retained notices, dataset cards and attribution. |
| `fetch.py`, `wikipedia.py` | Explicit pinned acquisition, latest complete Wikipedia resolution and archive verification. |
| `clean/`, `prepare.py` | Shared normalization, wikitext/XML extraction and offline preparation. |
| `prepare_raw_text.py`, `prepare_kenlm_raw.py` | Complete local raw extraction, shared unigram tokenization, sentence lineage and verified KenLM input. |
| `check.py` | Bundle hash, origin alignment and content/count verification. |
| `pinyin/build.py` | Explicit character and word reading tables from SI's maintained vocabulary. |
| `english.py`, `clean/dialogue.py` | Pinned English dialogue acquisition, source readers, immutable preparation and verification. |
| `english/sources.lock.json`, `english/licenses/`, `english/metadata/` | English source pins and retained full data terms/publisher notices. |
| `chinese/snapshot.json` | Measured first-batch text counts and checksums; not the corpus itself. |
| `chinese/raw/`, `chinese/prepared/`, `pinyin/generated/` | Local data, excluded from Git. |

Git retains the scripts, dependency pins, source lock, licenses/notices, snapshot
summaries and the reviewed Wikipedia completion/checksum metadata referenced by
the lock. Raw archives, prepared bundles, generated reading tables, `.venv/` and
caches stay local. A fresh checkout needs the explicit acquisition/preparation
steps below. Removing an existing artifact from Git tracking keeps its local
copy; it does not erase earlier commits or require downloading it again.

## Historical sources and fragment scope

The first lock selects LCCC-base's training archive, Chinese mC4 training shard
0 of 1,024, and the Chinese documentation trees of Kubernetes, TensorFlow and
MDN. This provides conversational, general web and technical writing. All five
raw archives were downloaded in full (about 1.02 GB combined); the legacy default
preparation retained at most **10,000,000 unique output Han characters per source**.
This is a bounded initial subset, not all Chinese mC4 or all LCCC. Documents are
processed in the pinned archive's member order; dialogue/web records remain in
their file order. New source versions need new pins, checksums and notice review.
The subsequent Wikipedia addition uses the latest complete **2026-10-01**
official Chinese `pages-articles.xml.bz2` dump, **3,430,912,430 bytes** compressed.
This is the full current-revision article archive, including both simplified and
traditional original wikitext. It is not a sampled download. Revision histories,
media binaries and discussion namespaces are outside the Chinese prose scope.
Official completion metadata and checksums are retained under
`chinese/metadata/wikipedia/20261001/`. The acquisition verifies Wikimedia's
SHA-1 before publishing the file and records an additional local SHA-256.
The verified initial Wikipedia text bundle contains **942,413 fragments** and
**9,999,995 Han characters**, stopping at the default ten-million-character
limit. It was at the now-deleted `chinese/prepared/wikipedia-20261001-v1/`; the separate
[Wikipedia snapshot](chinese/wikipedia-20261001.snapshot.json) records measured
counts and hashes. The original five-source snapshot remains unchanged. The
full raw dump is retained, so later full-text processing needs no new download.

The historical verified October 30, 2026 batch contained **2,598,415 fragments** and
**24,445,056 Han characters**, deduplicated within each source:

| Source | Fragments | Han characters | Selection |
| --- | ---: | ---: | --- |
| LCCC-base train | 1,160,555 | 9,999,997 | Character-limited prefix of the training archive. |
| mC4 Chinese | 1,010,816 | 9,999,980 | Character-limited prefix of training shard 0. |
| Kubernetes | 136,685 | 1,369,839 | Complete selected Chinese documentation tree. |
| TensorFlow | 25,777 | 263,275 | Complete selected Chinese Markdown/HTML tree. |
| MDN | 264,582 | 2,811,965 | Complete selected Simplified Chinese documentation tree. |

Sources stay in separate directories with their original data terms. In
particular, MDN's ShareAlike text is not silently pooled into a differently
licensed file. Read [the attribution and data terms](chinese/NOTICE.md) before
redistributing any derived data. The software remains GPLv3; it does not
relicense the corpora or decide the license of any future trained weights.

## Prepare the environment

Run from the repository root with Python 3.12+ and `hf` available on PATH:

```sh
python3 -m venv corpus/.venv
corpus/.venv/bin/python -m pip install -r corpus/requirements.txt
```

The only cleaning dependency is the hash-pinned Apache-2.0 OpenCC Python
implementation, version 0.1.7. Acquisition of the two Hugging Face files uses
`hf download` (the first batch used CLI 2.3.0); it is not a training dependency.
See [the official CLI installation guide](https://huggingface.co/docs/huggingface_hub/en/guides/cli)
if `hf` is unavailable. No authentication is required for these public sources.

## Download, prepare and verify

Each command performs only its stated stage. Only `fetch.py` accesses the
network. Offline preparation verifies the complete raw-file checksum first.

To explicitly resolve and acquire the newest complete Chinese Wikipedia dump:

```sh
python3 corpus/fetch.py wikipedia --latest
python3 corpus/fetch.py wikipedia --check
# Optional Wikimedia-listed mirror; official completion/checksum metadata is unchanged:
python3 corpus/fetch.py wikipedia --latest --mirror your-org
# Alternative listed university mirror:
python3 corpus/fetch.py wikipedia --latest --mirror acc-umu
```

`--latest` checks dated official directories in descending order, requires a
completed article-dump job, downloads and verifies the full file, then updates
only Wikipedia's source pin. It never treats a partly generated monthly dump as
complete. Other fetch commands use the existing pin and never silently change
source versions. `--mirror your-org` or `--mirror acc-umu` selects the Your.org
or Umeå University mirror listed by Wikimedia; the canonical URL and official SHA-1 stay in the pin alongside the
actual download URL. Large Wikipedia archives use at most three connections, the
official per-IP limit. Interrupted downloads retain `.range-N.part` files and
resume with validated HTTP byte ranges; unexpected ranges are rejected before
writing. Small single-stream transfers restart cleanly if a server ignores
Range. Every completed assembly must match the official checksum before it
becomes the raw archive. The completed raw archive is at
`chinese/raw/wikipedia/zhwiki-20261001-pages-articles.xml.bz2`.

To prepare the initial text subset, or process all eligible Wikipedia article
text with `--max-chars 0`, choose a fresh versioned destination:

```sh
corpus/.venv/bin/python corpus/prepare.py --source wikipedia --output corpus/chinese/prepared/wikipedia-20261001-v1
corpus/.venv/bin/python corpus/check.py --bundle corpus/chinese/prepared/wikipedia-20261001-v1
# Full text preparation, without the initial ten-million-character limit:
corpus/.venv/bin/python corpus/prepare.py --source wikipedia --max-chars 0 --output corpus/chinese/prepared/wikipedia-20261001-full-v1
```

```sh
python3 corpus/fetch.py all
python3 corpus/fetch.py all --check
corpus/.venv/bin/python corpus/prepare.py --output corpus/chinese/prepared/chinese-v1
corpus/.venv/bin/python corpus/check.py --bundle corpus/chinese/prepared/chinese-v1
corpus/.venv/bin/python corpus/pinyin/build.py --output corpus/pinyin/generated/lexical-v1
```

If an output already exists locally, choose a new output directory, for example
`chinese-v2` / `lexical-v2`, for another run. Outputs are not included in a fresh clone.
Preparation stages a complete bundle and refuses existing destinations; failed
processing leaves no published partial bundle. Fetching verifies cached files
and refuses corrupt caches; remove only the failed cache file explicitly before
retrying. Hugging Face handles its own resumable downloads; GitHub archive
downloads restart from the beginning on retry.

`fetch.py lccc` selects one source; `prepare.py --source mdn --output NEW_PATH`
prepares one. `--raw-root PATH` selects an explicit archive cache. Preparation
defaults to ten million unique output characters per source; `--max-chars 0`
processes **all of the pinned subset**. It does not fetch the other 1,023 mC4
shards. The limit counts after conversion and deduplication, never cuts a line,
and can stop slightly below the requested total.

Each text bundle contains a root `manifest.json`, copied source lock/licenses,
and one directory per source containing:

- `text.txt`: UTF-8, LF, one 4–96-Han-character fragment per line.
- `origins.jsonl`: one JSON string per corresponding text line, identifying
  its first archive path, raw record/turn or Wikipedia page/revision URL. Resolve it using the pinned source.
- `manifest.json`: source, counts, limit status and file hashes.

The root manifest records the preparation-code hashes, OpenCC version/config
and per-source results. `check.py --report NEW_FILE.json` writes an aggregate
integrity/count report; [snapshot.json](chinese/snapshot.json) retains the first
verified run's report in Git without committing the large data files.

## Cleaning contract

For language-model training on whole articles/paragraphs, use the independent
[small-reranker preparation stage](../llm/reranker_small/README.md). It reuses the
raw readers with title/English-spacing preservation, retains document text and
creates document-grouped token windows. The fragment preparation command below
keeps its existing behavior and does not replace earlier bundles.

Documentation processing removes front matter, fenced/inline code, HTML
comments/code blocks, template directives and table rows. Link labels remain;
markup becomes a boundary. LCCC's ASCII token spaces are removed within each
turn only. mC4 uses a simple prose filter: at least 64 nonspace characters in the
first 4,000 characters, at least half Han, and one contiguous eight-Han run.
This heuristic does not establish text quality or remove all spam.

Wikipedia XML is streamed one page at a time. Only namespace 0, nonredirect,
current wikitext revisions enter cleaning. Nested templates and tables,
references, category/media/interwiki links, headings, language-variant markup,
comments and code blocks become boundaries. Ordinary link display text remains.
Templates are not executed or expanded, so some template-generated prose is
intentionally absent. Origins carry both page ID and revision ID. Raw simplified
and traditional text remains untouched; OpenCC conversion applies to derived
text only. The official legacy XML dumps are scheduled for retirement in
January 2027; a future source-format migration will need separate validation
against [MediaWiki Content File Exports](https://dumps.wikimedia.org/other/mediawiki_content_history/readme.html).

All text is converted using OpenCC `t2s`. Non-Han text, punctuation, line breaks,
digits and Latin letters separate fragments; they never join surrounding Han
runs. Unified Han ideographs and extensions through I are supported; Unicode
compatibility ideographs are excluded. Runs longer than 96 characters are split
into chunks; fragments shorter than four characters are dropped. Exact duplicate
lines are removed **within each source**, retaining the first occurrence and its
origin. SQLite holds the full deduplication keys on disk rather than keeping all
strings in RAM or using collision-prone truncated hashes.

The result is Chinese fragment text, not intact documents, punctuation training
data, a frequency-preserving corpus, or labeled Pinyin sentences. Conversion and
short-fragment filtering change the original distribution. Different sources
may still overlap. No automatic train/validation/test split is assigned; future
training must freeze its source selection, remove evaluation overlap and group
duplicate inputs/outputs before choosing splits. Existing SI held-out CSVs are
not imported or reassigned.

## Pinyin resources

`pinyin/build.py` reuses `scripts/csv_dictionary.py`'s validated category merging,
source weights and deterministic ordering. It exports `characters.tsv` and
`words.tsv` with `text`, apostrophe-separated toneless `reading`, and `weight`.
Every Han character must align to one supplied syllable. Polyphonic alternatives
remain separate rows; unaligned/non-Han entries are counted and excluded.
Existing exact lexical bytes are preserved, including traditional forms, rather
than silently simplifying dictionary outputs. These tables therefore use `zh`,
whereas cleaned text uses `zh-Hans`.

The first export has **49,354 character/reading pairs**, **2,091,723 word/reading
pairs**, and **125 excluded entries**, recorded in [the lexical snapshot](pinyin/snapshot.json). Counts are pairs, not unique characters
or words. Weights remain dictionary ranking values, not measured corpus
frequencies. The bundle copies existing vocabulary provenance and attribution.
This does not guess context-dependent sentence pronunciations; sentence Pinyin
annotation is a separate future data step.

## Validation and boundaries

```sh
corpus/.venv/bin/python -m unittest discover -s corpus/tests -v
./scripts/test.sh
./scripts/build.sh
```

Synthetic regressions cover boundaries, simplified conversion, supplementary
Han, markup/code exclusion, source/turn isolation, deterministic source order,
exact deduplication, limits, immutable outputs, checksum rejection and rollback.
Wikipedia cases also cover namespace/redirect filtering, page/revision origins,
nested markup, official checksum corruption and safe range-download restart.
See [the repository verification guide](../docs/TESTING.md).

These tools do not start training, select an input source, install SI, change
runtime dictionaries or load a neural model into the app. Personal phrases,
app vocabulary, documents, clipboard text and typing histories are not sources.
Existing `llm/` prepared datasets, checkpoints and defaults remain independent.
