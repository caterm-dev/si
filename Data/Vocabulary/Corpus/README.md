# Reviewed Chinese corpus vocabulary

The November 4, 2026 review adds **266 text/reading pairs** in the separate
[`../chinese/corpus.csv`](../chinese/corpus.csv) category and makes **eight
bounded base-weight corrections**. The merged Chinese dictionary has
**2,141,468 entries**. No decoder constants, language settings, learning,
history, model loading or input-event behavior change.

For review:

- [`accepted.csv`](accepted.csv): the added terms, explicit readings, adopted
  weights, HanLP occurrence/fragment counts and six separate source counts,
  ordered by observed frequency.
- [`../chinese/corpus.csv`](../chinese/corpus.csv): only the actual additions,
  using the normal `text,reading,weight` runtime compiler contract.
- [`corrections.csv`](corrections.csv): all eight old/new weights, prior
  homophone leaders and independently recounted surface evidence.
- [`decisions.json`](decisions.json): every adopted reading and all 197 excluded
  proposals, with exclusion reasons. All **463** eligible proposals were
  classified; an exclusion is not a claim that the string is always invalid.
- [`snapshot.json`](snapshot.json): measured totals, exact input/model/code
  hashes, package versions, original vocabulary hashes and source terms.

The full token and frequency tables remain local under
`corpus/chinese/generated/hanlp-words-v1/` and
`corpus/chinese/generated/hanlp-review-v2/`. In the latter, `frequencies.csv`
contains every observed token, and `decisions.csv` combines the eligible
proposals, per-source counts, decisions and readings. Generated corpus tables
remain outside Git; the small reviewed selection and measured snapshot are
maintained provenance artifacts.

## Observations and filtering

HanLP 2.1.3 `COARSE_ELECTRA_SMALL_ZH` processed all **3,540,828 fragments** and
**34,445,051 Han characters** in the six existing prepared source subsets,
yielding **20,347,213 token occurrences**. Every token file was independently
recounted against exact source text and compared with stored word/fragment
counts. No model dictionary was forced into segmentation.

| Source | Token occurrences | Distinct observed tokens |
| --- | ---: | ---: |
| LCCC dialogue | 6,826,331 | 118,667 |
| mC4 web | 5,506,326 | 292,393 |
| Kubernetes | 811,541 | 10,059 |
| TensorFlow | 154,627 | 4,691 |
| MDN | 1,679,699 | 14,638 |
| Chinese Wikipedia | 5,368,689 | 252,322 |

Review considers missing 2–7-Han-character words and stable terms with at least
20 occurrences in at least 10 distinct fragments. It additionally requires
three containing fragments in each of at least two sources, or at least 100
containing fragments for a single-source term. Single-character repetitions
and other lengths/scripts are excluded before manual review. Low corpus counts
do **not** delete existing dictionary words.

The adopted selection includes ordinary words such as `唇釉`, technical terms
such as `跨源` and `编排器`, stable compound terms such as `新闻发布会` and
`可持续发展`, and recognizable complete institutional/geographic names. Readings
were reviewed manually and checked against the maintained character readings.
Some established regional lexical forms, such as `义大利` and `萤幕`, remain
distinct output choices; no output normalization is introduced.

Manual exclusions cover gambling-site advertising/brand noise, mojibake,
unverified or incomplete names, nonpreferred spelling/conversion variants,
interjection repetitions, numerical/time templates and incomplete spans such
as `视化`, `直方`, `冠肺炎` and `扩缩`. `配器` is a valid music term, but its
apparent cross-source support includes wrongly split `适配器`, so this review
does not adopt it. Context sampling also confirmed complete uses of ambiguous
terms such as `其时`, `时值`, `时人`, `王庭` and `降伏`.

Counts are uncorrected HanLP observations. Manual term review does not label or
correct every token occurrence. The prepared inputs are deduplicated,
punctuation-separated, simplified fragments, with character-limited LCCC, mC4
and Wikipedia subsets. They are not all downloaded raw text, representative
conversation frequencies, gold segmentation or an independent accuracy test.

## Weights

New terms use the median existing positive dictionary weight among words with
one maintained reading, identical character length and the same
`floor(log2(HanLP count))` bin, clamped to **10–5,000**. No anchors means the
existing default 10. This explicit editorial prior is a documented exception to
the earlier local-category weight-10 policy. It does not turn raw counts into
Wanxiang points or rescale existing vocabulary. Base/imported precedence and
all other local category weights remain unchanged.

Comparing HanLP token counts alone can misrank combinations the model splits,
such as `是在` or `有一`. Existing-word corrections therefore compare the
target's token count against **all exact, overlapping surface occurrences** of
the prior homophone leader, including appearances inside longer words. This is
a conservative upper bound for the reference word. Fragment boundaries never
join. The target needs at least 100 tokens, at least four times the total
reference count, and at least 10 tokens and twice the reference count in LCCC,
mC4 and at least one other source. Pronunciation-ambiguous targets are excluded.

| Reading | Word | Old weight | New weight | Prior same-reading leader |
| --- | --- | ---: | ---: | --- |
| `da'lian` | 大连 | 6,493 | 11,002 | 打脸 (10,478) |
| `di'dang` | 抵挡 | 1,516 | 2,404 | 低档 (2,289) |
| `fu'jian` | 福建 | 5,752 | 10,366 | 附件 (9,872) |
| `mao'ming` | 茂名 | 150 | 287 | 冒名 (273) |
| `shao'guan` | 韶关 | 656 | 726 | 少管 (691) |
| `xiang'tan` | 湘潭 | 527 | 842 | 详谈 (801) |
| `xiao'ji` | 消极 | 3,074 | 5,473 | 小鸡 (5,212) |
| `yin'ni` | 印尼 | 2,245 | 4,165 | 因你 (3,966) |

Each new value is the ceiling of 105% of the old leader's weight, bounded by
twice the target's old weight. These are editorial lexical preferences, not a
guarantee about complete-sentence leaders. No reference word is removed or
downweighted. Prior requested adjustments for `上次`, `长的` and `语料` remain.

The eight corrections edit their authoritative `chinese/base.csv` rows;
category copies cannot override base weights. A fresh Wanxiang conversion
replaces these edits, just as it replaces prior SI editorial base adjustments.
Review/reapply the recorded corrections when deliberately refreshing upstream;
ordinary CSV builds preserve them. The new category survives upstream refresh.

## Reproduce and verify

Follow [the offline HanLP workflow](../../../corpus/HANLP_WORDS.md), using the
exact source/model pins in the snapshot. Full analysis artifacts stay local.
The retained decisions are an explicit manual step; fresh reports are never
automatically adopted into runtime CSVs. To recheck the correction evidence:

```sh
corpus/.venv/bin/python corpus/check_word_corrections.py \
  --corrections Data/Vocabulary/Corpus/corrections.csv \
  --segmented corpus/chinese/generated/hanlp-words-v1 \
  --bundle corpus/chinese/prepared/chinese-v1 \
  --bundle corpus/chinese/prepared/wikipedia-20261001-v1
python3 scripts/csv_dictionary.py build
python3 scripts/csv_dictionary.py build --check
python3 scripts/msime_dictionary.py build --check
python3 -m unittest discover -s Tests/VocabularyTests -v
./scripts/test.sh
./scripts/build.sh
```

## Attribution and retained data

The independent recount, correction-span checks, both runtime dictionary checks
and pinned context checks passed. All 38 corpus tests and 435 Swift tests
passed, and the Debug app built. Vocabulary maintenance passed 43/44 tests; the
unchanged English domain metadata mismatch remains. Runtime comparison found
exactly the 266 additions and eight weight edits, with no removals and identical
English bytes. No installation or live-host check was performed. See
[the validation record](../../../docs/TESTING.md#hanlp-corpus-vocabulary-review).

The model and Python dependencies remain local analysis tools and are not
bundled with SI. The Chinese pretrained model has separate research/teaching
terms; HanLP's Apache-2.0 code license does not relicense its model. No training
or remote inference is performed.

The six corpora retain their recorded MIT, ODC-BY-1.0, CC-BY-4.0, Apache-2.0,
CC-BY-SA-2.5 and CC-BY-SA-4.0 terms. Exact revisions, modifications, source
credits and license checksums are retained in the snapshot and
[corpus attribution](../../../corpus/chinese/NOTICE.md). Full source notices
and licenses accompany the dictionary in
[`Corpus-NOTICE.txt`](../../../mac/SI/Core/Resources/Chinese/Corpus-NOTICE.txt).
No corpus passages or model weights are added to the app. SI's manual curation
and reading annotations remain GPL-3.0-only; this does not relicense source
material or assert blanket rights over original web documents. No personal
phrases, learning records, Input History, host documents or clipboard are inputs.
