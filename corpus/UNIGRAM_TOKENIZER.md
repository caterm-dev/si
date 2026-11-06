# Streaming unigram corpus tokenizer

[`tokenize_unigram.py`](tokenize_unigram.py) is an independent, standard-library
Python 3.12+ script for preparing user-selected UTF-8 text. It uses a supplied
frequency dictionary and Viterbi decoding, without HanLP, a pretrained model,
network access or input-method integration. It does not train anything or
modify the input, dictionary, earlier prepared bundles or runtime vocabulary.

## Run

From the repository root, supply a plain UTF-8 text file and a **new** output
path. For example, use the word-side dictionary built with
`python3 corpus/build_word_dictionary.py`:

```sh
python3 corpus/tokenize_unigram.py \
  --input corpus/chinese/prepared/raw-text-v1/lccc/text.txt \
  --dictionary corpus/chinese/dictionaries/generated/unigram-words-v2/frequencies.csv \
  --output corpus/chinese/generated/unigram-v1/lccc.txt \
  --workers 4 --chunk-lines 1000 --chunk-bytes 1048576 --max-in-flight 8 \
  --sentence-punctuation '。！？.!?' \
  --output-origins corpus/chinese/generated/unigram-v1/lccc-origins.jsonl
```

Replace `--input` with the text being cleaned. The retired Han-only fragment
bundles were deleted at the user's request.
Use `prepare_raw_text.py` to extract complete lines from local raw archives;
keep each source and its terms separate. This command
reads text lines, not JSON records or compressed archives.

Dictionary formats:

- CSV/TSV with `text,count` columns; `word` and `freq`/`frequency` are accepted
  aliases. Additional columns, including those in `frequencies.csv`, are ignored.
- Headerless two-column CSV/TSV, or plain `word frequency` lines.

Frequencies must be nonnegative integers. Zero-frequency entries and entries
outside `\u4e00–\u9fff` are excluded. At least one positive Han entry is required.
Dictionary words receive the same NFKC/invisible-character cleaning; duplicate
normalized words have their counts summed. UTF-8 BOMs and plain-text comment
lines beginning with `#` are accepted. Invalid Han frequencies/records fail with
a record number. SI's `text,reading,weight` CSVs are deliberately not treated as
frequency dictionaries: their ranking weights are not occurrence counts.

## Exact processing rules

1. Normalize each physical input line with Unicode **NFKC**. Remove control,
   format and surrogate characters, invisible fillers, variation selectors and
   blank braille characters. Whitespace controls such as tabs become ordinary
   spaces, preserving word boundaries; whitespace is discarded during
   tokenization. Visible combining marks are not indiscriminately removed.
2. By default, split at Chinese/English periods, commas, question marks, exclamation marks,
   semicolons, colons and the Chinese enumeration comma. Keep punctuation
   clusters and immediately adjacent closing quotes/brackets on the preceding
   sentence. Preserve decimal points and apostrophes/hyphens inside English
   words. A final fragment needs no terminating punctuation. This is punctuation
   splitting, without abbreviation or URL sentence-boundary heuristics. The raw
   workflow above overrides boundaries to `。！？.!?`, retaining commas,
   enumeration commas, semicolons and colons within a sentence.
3. Extract fragments using exactly:

   ```text
   [\u4e00-\u9fff]+
   [A-Za-z]+(?:['\-][A-Za-z]+)*
   \d+(?:\.\d+)?
   any other single non-whitespace character
   ```

   Han extensions outside the requested range remain individual symbol tokens.
   Only ASCII apostrophes/hyphens participate in English words. Unicode decimal
   digits match `\d`; the number grammar does not add signs or exponents.
4. Decode each Han fragment with suffix Viterbi, maximizing the sum of natural
   log probabilities `ln(count) - ln(total positive Han count)`. The maximum word
   length is the actual longest dictionary word, with no fixed seven-character
   limit. Every unknown Han character has a fallback score exactly **five nats
   below the lowest dictionary log probability**, so a path always exists.
   Exact score ties prefer the longer first token, independently of dictionary
   row order. This is maximum-probability decoding, not greedy longest matching.
5. Lowercase English words; retain numbers and symbols as they appear **after
   NFKC**. Thus fullwidth `１２.５０！` becomes `12.50 !`, as required by the
   preprocessing step. No punctuation mapping beyond NFKC is performed.
6. Drop whitespace-only/empty results and sentences with **more than 100 output
   tokens**, counting punctuation/symbols as tokens. Exactly 100 is retained.
   Nonempty punctuation-only input is retained; no unrequested content filter
   is applied. The limit is per sentence after splitting, not per original line.
7. Write one sentence per UTF-8/LF line, with exactly one ASCII space between
   tokens, no surrounding spaces or blank lines, and no added `<s>`, `</s>` or
   `<unk>` markers. Unknown text is emitted as its actual characters.

For boundaries limited to periods, question/exclamation marks and semicolons:

```sh
python3 corpus/tokenize_unigram.py \
  --input INPUT.txt --dictionary COUNTS.csv --output NEW_OUTPUT.txt \
  --sentence-punctuation '。！？.!?；;'
```

## Parallelism, memory and progress

The script uses a spawned `ProcessPoolExecutor`, including on macOS. The parent
loads/validates the dictionary once and initializes one worker-local copy per
process. Workers process **line chunks**; the parent writes completed chunks in
submission order, so output order is deterministic across worker counts.

The defaults are at most eight workers, 1,000 lines/1 MiB per chunk and twice the
worker count in flight. `--max-in-flight` is a hard cap on submitted chunks;
there is no unbounded `imap` prefetch or list of all futures. A chunk flushes
when adding a line would exceed its line/byte budget. An individual physical
line is never truncated, so a line larger than the byte budget forms its own
chunk. Memory includes one dictionary copy in the parent and each worker,
bounded in-flight chunks/results, and the largest individual input line; it
does not scale with the number of file lines. Choose fewer workers for a large
dictionary or limited RAM.

Progress goes only to **stderr**: processed input-byte percentage, original
lines, written sentences, empty lines, over-limit sentences and elapsed time.
It advances after ordered results are written, without scanning the input a
second time for a line count. It refreshes while waiting for workers. `--quiet`
suppresses progress; stdout is never mixed into corpus content.

The output is streamed into a same-directory temporary file, then published
atomically without replacing an existing destination. A failure or interruption
removes the temporary file and leaves no published partial output. Existing
outputs are refused. Generated files under `corpus/**/generated/` stay ignored;
they remain local until explicitly deleted. Only caller-selected text/count
files are read; no live learning/history archive or host text is accessed.
Source licenses and privacy obligations still apply to the selected inputs.

## Verify

```sh
corpus/.venv/bin/python -m unittest corpus.tests.test_tokenize_unigram -v
corpus/.venv/bin/python -m unittest discover -s corpus/tests -v
```

Synthetic fixtures cover global Viterbi ambiguity, unknown characters, stable
ties, dictionary-length bounds, NFKC/invisibles, exact fragment grammar, decimal
and English-word protection, closing punctuation, the inclusive 100-token limit,
byte/line chunk bounds, spawned one-/two-worker byte equality, UTF-8 failures,
existing-output preservation and exact output formatting. This script has no
effect on SI's runtime candidate engine or host event handling.

On November 5, 2026, all 50 corpus-tool tests passed. A separate two-worker
streaming check processed 100,000 synthetic input lines into 300,000 sentences
and compared every sentence with the expected ordered output. A second check
loaded the existing 530,015-Han-entry occurrence CSV (maximum word length 96)
and verified mixed-text output formatting. The current worktree's 443 Swift
tests passed with `./scripts/test.sh --disable-sandbox`, and the Debug app built
with normal Xcode compiler/package-cache access. Logs are local in
`/tmp/si-unigram-*.log`; these checks do not process the full corpus or install SI.

The [raw-derived KenLM workflow](KENLM_DATA.md) runs this exact engine on
all six complete local raw archives. It retains numbers, punctuation, short
spans and repeated occurrences; the obsolete Han-fragment batch was deleted.

## Optional source-line map

`--output-origins NEW_MAP.jsonl` writes one `[input_line, sentence_index]` pair
per emitted sentence, both one-based. Filtered sentences do not get a row, but
their positions remain reflected in later sentence indices. The sidecar does
not change tokenized text, ordering or default behavior. Existing text/map paths
are refused; processing errors clean up unpublished outputs. The raw batch uses
this map plus its input document ranges to locate the original record exactly.
