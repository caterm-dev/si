# Raw Chinese corpus to KenLM input

The measurements and commands below describe frozen six-source runs using
`raw-text-v1`. The current extractor now writes OpenCC-t2s `raw-text-v2` and
supports local `si` and `dialogue` sources; see [the current preparation guide](README.md).
The old prepared `raw-text-v1` directory was deleted on November 8, 2026.
The commands below remain a historical record; these changes do not regenerate
this record or extend the existing six-source tokenization/training pipeline
automatically.

## Current word-only rebuild (v2)

The current run uses only flat `Data/Vocabulary/chinese/*.csv` text columns
as its vocabulary source. `chinese/phrase/` and every other subdirectory are
excluded from discovery; no phrase CSV supplies words or weights. A word also
independently present in a flat word CSV remains eligible, even when the poetry
collection happens to contain the same text. This is source exclusion, not a
ban on normal words shared with verse titles or excerpts.

```sh
python3 corpus/build_word_dictionary.py
python3 corpus/prepare_kenlm_raw.py tokenize --workers 4
python3 corpus/prepare_kenlm_raw.py finalize
```

The frozen derived dictionary lives under
`corpus/chinese/dictionaries/generated/unigram-words-v2/`; its manifest records
every word-source hash and the prior corpus-count reference hash. After NFKC,
it contains **1,736,611** distinct positive-frequency Han entries, maximum
length **24**. Of these, 198,021 have observed reference counts; the remaining
1,538,590 receive an explicit pseudocount of 1. Input-method ranking weights
and readings are never treated as corpus counts. These pseudo-counts are a
smoothing policy, not measurements of general language frequency. The lexical
selection remains the user's conservative word/phrase split, not an assertion
that every retained entry is linguistically indivisible.

All six complete raw-derived sources are re-tokenized, with new per-sentence
origins and full normalized-source verification. The current output directory
is `corpus/chinese/generated/kenlm-words-v2/`; the combined input is
`kenlm-input.txt` after all source checks finish. The full raw-text extraction
is reused without changing its original numbers, English or punctuation.
The preceding v1 output is a historical artifact and is not reused as input.
No model training or split assignment is performed.

## Completed word-only v2 measurements

All six sources have completed re-tokenization and full source-retention
verification. The combined input contains **59,811,874 sentences** and
**871,659,206 tokens**, including punctuation. Of 60,065,125 candidate
sentences, 253,251 exceeded 100 output tokens and were filtered.
14,106,701 retained sentences contain digits; 8,169,376 contain English words.
The physical input lines, empty lines and candidate-sentence counts exactly
match v1: only the segmentation dictionary changed.

| Source | Output sentences | Output tokens | Over 100 tokens |
| --- | ---: | ---: | ---: |
| lccc | 23,198,760 | 145,954,069 | 150 |
| mc4 | 1,200,736 | 23,346,465 | 32,975 |
| kubernetes | 164,108 | 1,753,719 | 41 |
| tensorflow | 40,619 | 394,421 | 5 |
| mdn | 272,384 | 2,893,368 | 14 |
| wikipedia | 34,935,267 | 697,317,164 | 220,066 |

Combined size: **4,322,204,298 bytes**; SHA-256
`92660454982b99a22c815871b3345ed664cd04493ae8c2471aa781540f470f47`.

The [v2 snapshot](chinese/kenlm-words-v2.snapshot.json) records the exact word
sources, counts, smoothing, code/output hashes and validation. The generated
output also retains `dictionary/`, `dictionary-audit.json`, per-source origins,
attribution and `source-examples.txt`. Every source uses the same dictionary
hash. Independent vocabulary auditing confirms exact equality to normalized
flat word-side CSVs; no phrase directory contributes vocabulary or counts.
Ordinary word-side entries can still be compositional: this follows the user's
conservative classification and does not establish exhaustive linguistic labels.

Validation: 60 corpus unit tests, all 443 Swift tests and the Debug build passed.
No KenLM fitting, installation or train/development/test split was performed.

## Historical v1 workflow and measurements

The former Han-fragment training batch was withdrawn and deleted on November 5,
2026 at the user's request. Its source preparation had removed numbers,
punctuation and short spans. It must not be reused as complete-sentence text.

The current rebuild reads **all six pinned local raw archives**, without the
old character limits, four-character minimum, 96-character cuts or deduplication.
It uses the existing `tokenize_unigram.py` engine. No model training is started.

## Reproduce

Run from the repository root with Python 3.12+, the pinned local raw archives
and the retained fixed frequency reference (these commands do not download data):

```sh
python3 corpus/prepare_raw_text.py --source all
python3 corpus/prepare_kenlm_raw.py tokenize --workers 4 \
  --dictionary corpus/chinese/dictionaries/generated/unigram-reference-v1/frequencies.csv \
  --output-root corpus/chinese/generated/kenlm-raw-v1
python3 corpus/prepare_kenlm_raw.py finalize --output-root corpus/chinese/generated/kenlm-raw-v1
```

Each extraction/tokenization source is published separately after successful
processing and can be resumed by running the same command again. Existing
completed sources must match their source/code/dictionary hashes. Finalization
requires all six sources and verifies every combined-file byte range.

## Locations

- Raw archives: `corpus/chinese/raw/`.
- Complete raw-derived plaintext: `corpus/chinese/prepared/raw-text-v1/{source}/text.txt`.
- Raw document/turn/page ranges: `corpus/chinese/prepared/raw-text-v1/{source}/documents.jsonl`.
- Tokenized text: `corpus/chinese/generated/kenlm-raw-v1/{source}/text.txt`.
- Sentence lineage: `corpus/chinese/generated/kenlm-raw-v1/{source}/origins.jsonl`.
- Combined input, available after finalization:
  `corpus/chinese/generated/kenlm-raw-v1/kenlm-input.txt`.
- Verified original-example comparisons: `corpus/chinese/generated/kenlm-raw-v1/source-examples.txt`.
- Counts, source pins, source ranges and checksums:
  `corpus/chinese/generated/kenlm-raw-v1/manifest.json`.

A sentence lineage row is `[input_line, sentence_index]`, both one-based.
`input_line` points into the source's complete raw-derived `text.txt`;
`documents.jsonl` maps that line into an original JSON row/turn, archive path,
or Wikipedia page/revision. This mapping includes filtering: dropped long
sentences do not shift or fabricate later origins.

## Content contract

mC4 JSON text is retained without the former Han-ratio filter. LCCC preserves
turn boundaries, digits, punctuation and English word spacing; only artificial
spaces between adjacent Han/CJK-punctuation tokens are restored. Markdown and
Wikipedia use the existing prose/markup readers. Wikipedia keeps namespace-0
nonredirect current articles, with titles, and excludes markup/code/templates/
tables/references. Original physical text-line boundaries remain boundaries;
removed or never-captured web content is not invented.

No Simplified/Traditional conversion is applied. The tokenizer performs NFKC,
control/invisible removal, lowercase English and unigram Viterbi. The raw batch
sets sentence boundaries to **`。！？.!?`**: commas, enumeration commas, colons
and semicolons remain within the sentence. Decimal points and in-word English
apostrophes/hyphens are protected. Empty results and sentences longer than
100 output tokens are filtered, including punctuation in that token count.
Unknown Han characters remain literal single-character tokens.

The fixed frequency reference is
`corpus/chinese/dictionaries/generated/unigram-reference-v1/frequencies.csv`.
It was retained, with its hash and original attribution, solely as the lexical
reference required by the custom tokenizer. Its counts come from the earlier
HanLP vocabulary observations; it is not an old training-text bundle, fresh
raw-data frequency estimate or a neural segmentation step. It has 530,015
positive-frequency Han words and a maximum word length of 96. The previous
cleaned texts and derived token files were deleted; raw archives, maintained
application dictionaries and unrelated model artifacts were preserved.

## Verification and scope

The raw extraction verifies complete archive hashes before reading. Tests cover
retention of years, decimals, English, punctuation, short spans, duplicates and
full lines longer than 96 characters. Tokenization uses the original shared
engine, with a JSONL lineage sidecar. Independent verification uses a Unicode translation-table normalizer, checked
against the tokenizer across every Unicode code point and combining sequences.
It checks every retained sentence against its normalized source characters, validates
whitespace/token limits and confirms that every omitted nonempty sentence
actually exceeds 100 tokens. Examples with years and enumeration commas have
regressions; unexplained sentence loss is an error.

The final input uses UTF-8/LF, one sentence per line, single ASCII spaces and no
explicit `<s>`, `</s>` or `<unk>` markers, matching the
[KenLM formatting contract](https://kheafield.com/code/kenlm/estimation/).
The source files remain separate, and combination does not relicense any data.
Source notices and full terms accompany the artifacts. There is no automatic
content-quality classifier, train/development/test assignment or model fitting.
Generated data remain local and ignored by Git.

## Measured November 5, 2026 rebuild

All six sources completed extraction, tokenization and full source-retention
verification. The combined input contains **59,798,702 sentences** and
**907,459,538 tokens**, including punctuation. Input processing examined
71,956,292 physical text lines; 266,423 candidate sentences exceeded 100 tokens
and were filtered. There are 14,099,322 retained sentences containing digits
and 8,166,232 containing ASCII English words. No empty output lines or explicit
KenLM sentence/unknown markers are written.

| Source | Raw-derived input lines | Output sentences | Output tokens | Over 100 tokens |
| --- | ---: | ---: | ---: | ---: |
| lccc | 20,073,720 | 23,198,639 | 164,773,744 | 271 |
| mc4 | 588,133 | 1,200,039 | 24,264,365 | 33,672 |
| kubernetes | 341,175 | 164,108 | 1,800,167 | 41 |
| tensorflow | 56,287 | 40,619 | 404,140 | 5 |
| mdn | 410,068 | 272,383 | 3,000,466 | 15 |
| wikipedia | 50,486,909 | 34,922,914 | 713,216,656 | 232,419 |

Combined size: **4,352,662,268 bytes**. SHA-256:
`761ba51ace202fda42b80ec4f95b9bd15f6e4e07ce144c2c88943d52672f1f50`.

The [maintained snapshot](chinese/kenlm-raw-v1.snapshot.json) records actual
source counts, archive/output/code/dictionary hashes, checks and the deletion
receipt. Full data and example comparisons remain local and Git-ignored.
The two reported examples were matched to their actual new mC4 output lines:
`2017` and the date remain present, and the Google/Xiaomi/Huawei title remains
one complete question. The latter raw record contains title/navigation/date
only; missing article body content is not synthesized.

Validation: 58 corpus unit tests passed, including every-Unicode-code-point
normalization parity and raw-to-token lineage regressions; all 443 Swift tests
and the Debug application build passed. No installation, dataset split or
KenLM training was performed.
