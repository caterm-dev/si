# HanLP word-frequency review

This is the historical vocabulary-analysis workflow. The local Han-fragment
bundles and their derived HanLP/token tables were deleted on November 5, 2026
at the user's request. The [current vocabulary](../docs/CHINESE_VOCABULARY.md) is maintained as
counted CSVs. The [unigram tokenizer](UNIGRAM_TOKENIZER.md) accepts separately
supplied occurrence counts.

This workflow uses HanLP as a **local, offline corpus-analysis tool**. It does
not add HanLP, a Python interpreter, a neural model or host-text inspection to
the input method. Vocabulary changes still use the existing CSV compiler and
Rust engine.

## Inputs and model

The historical inputs were all six prepared Chinese sources:
`chinese/prepared/chinese-v1/` and
`chinese/prepared/wikipedia-20261001-v1/`. Together they contained 3,540,828
fragments and 34,445,051 Han characters. That run processed every line of those
bundles, **not every record of the larger downloaded raw archives**. The LCCC,
mC4 and Wikipedia preparations stopped at their documented character limits.

These are simplified, punctuation-separated, 4–96-character fragments,
deduplicated within each source. Their counts measure occurrences in this
prepared collection, not original dialogue frequency or general Chinese usage.
Sources stay separate; technical documentation and Wikipedia are not treated as
a representative conversation sample. The original audit recorded source and
one-based fragment line numbers; those local fragment/origin files have since
been deleted. See [the corpus guide](README.md) and
[source notices](chinese/NOTICE.md) for transformations and data terms.

The model is HanLP 2.1.3's
[`COARSE_ELECTRA_SMALL_ZH`](https://hanlp.hankcs.com/docs/api/hanlp/pretrained/tok.html),
published as `coarse_electra_small_20220616_012050.zip`. No SI dictionary is
forced into segmentation (`dict_force` and `dict_combine` are disabled), so
existing vocabulary cannot dictate the measured boundaries. Each prediction
must concatenate to the exact input fragment. Both occurrence count and number
of containing fragments are retained.

[HanLP code](https://github.com/hankcs/HanLP) is Apache-2.0. Chinese pretrained
models have separate research/teaching restrictions unless otherwise specified;
the Apache code license does not relicense the model. We retain the model
locally for this analysis, without shipping it in SI. Corpus-derived data retain
their source terms; this analysis does not assert a new blanket license for
the corpora or derived material.

## Reproduction records

The original analysis used verified fragment bundles and retained per-source
`text,count,line_count` totals, a candidate review, and manual decisions.
The tool that joined those totals to the retired vocabulary layout is
available with the earlier dictionary metadata in Git. The HanLP model
loader also serves the [Chinese vocabulary migration](../Data/Chinese/README.md).

```sh
git show 0509cb3:corpus/review_words.py
git show 90dae8b^:Data/Vocabulary/Corpus/README.md
```
