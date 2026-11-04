# HanLP word-frequency review

This workflow uses HanLP as a **local, offline corpus-analysis tool**. It does
not add HanLP, a Python interpreter, a neural model or host-text inspection to
the input method. Vocabulary changes still use the existing CSV compiler and
shared Swift engine.

## Inputs and model

The selected inputs are all six existing prepared Chinese sources:
`chinese/prepared/chinese-v1/` and
`chinese/prepared/wikipedia-20261001-v1/`. Together they contain 3,540,828
fragments and 34,445,051 Han characters. This processes every line of those
bundles, **not every record of the larger downloaded raw archives**. The LCCC,
mC4 and Wikipedia preparations stopped at their documented character limits.

These are simplified, punctuation-separated, 4–96-character fragments,
deduplicated within each source. Their counts measure occurrences in this
prepared collection, not original dialogue frequency or general Chinese usage.
Sources stay separate; technical documentation and Wikipedia are not treated as
a representative conversation sample. Existing origins remain available by
source and one-based line number. See [the corpus guide](README.md) and
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

## Reproduce

Run from the repository root:

```sh
corpus/.venv/bin/python -m pip install -r corpus/requirements-hanlp.txt
# Explicit network stage: obtains model, tokenizer and normalization assets only.
corpus/.venv/bin/python corpus/hanlp_words.py fetch
# Verify both frozen input bundles first.
corpus/.venv/bin/python corpus/check.py --bundle corpus/chinese/prepared/chinese-v1
corpus/.venv/bin/python corpus/check.py --bundle corpus/chinese/prepared/wikipedia-20261001-v1
# Offline inference; use --device cpu when Metal is unavailable.
corpus/.venv/bin/python corpus/hanlp_words.py segment \
  --bundle corpus/chinese/prepared/chinese-v1 \
  --bundle corpus/chinese/prepared/wikipedia-20261001-v1 \
  --device mps --batch-size 512 --output corpus/chinese/generated/hanlp-words-v1
corpus/.venv/bin/python corpus/hanlp_words.py verify \
  --bundle corpus/chinese/prepared/chinese-v1 \
  --bundle corpus/chinese/prepared/wikipedia-20261001-v1 \
  --output corpus/chinese/generated/hanlp-words-v1
corpus/.venv/bin/python corpus/review_words.py \
  --segmented corpus/chinese/generated/hanlp-words-v1 \
  --output corpus/chinese/generated/hanlp-review-v2
corpus/.venv/bin/python -m unittest discover -s corpus/tests -v
```

`fetch` records exact model/cache-file hashes and inference-library versions in
`corpus/.cache/hanlp/model-lock.json`. `segment` verifies this lock and input
hashes, then blocks network connections. Caches, segmented text, token counts
and automatic review reports remain under ignored local paths. Completed
25,000-line chunks have checksums and can be resumed with the identical command
and configuration. Changed inputs, code, dependencies or device require a fresh
output directory. Only a complete pass publishes the root `manifest.json`.

Each source has `counts.csv` (`text,count,line_count`), a manifest, and numbered
chunks containing token JSONL and counts. Token-line order follows source text
and origins. The review directory contains:

- `frequencies.csv`: every token with per-source counts and initial status.
- `missing.csv`: absent 2–7-Han-character words eligible for manual review.
- `existing.csv`: sufficiently supported existing words, readings and weights.
- `manifest.json`: source/vocabulary hashes, filter counts and weight policy.

## Review and weight boundaries

New-word review considers 2–7-character words and stable terms, matching the
Chinese lattice's seven-syllable lexical-span bound. It requires at least 20 occurrences in at least 10 distinct
fragments, plus support in at least two sources (three containing fragments
per supporting source), or at least 100 containing fragments for a single-source
term. Single characters, non-Han tokens, lengths outside 2–7 and repeated-single-
character strings are excluded. These gates do not establish correctness.
Manual review must additionally remove unverified/incomplete names, incomplete affixes, accidental
cross-word spans, typos and source-specific noise, and verify explicit readings.
Rejected frequent proposals need an explicit recorded reason. Low-frequency
words are excluded from additions, **not deleted from the existing dictionary**.

Raw counts are not in Wanxiang's ranking-weight unit. For a new word, the report
suggests the median existing positive weight among unambiguous-reading words
of the same character length and `floor(log2(count))` bin, clamped to 10–5,000.
This is an editorial prior anchored to the current dictionary, not a measured
probability or a new global frequency scale. If there are no anchors it uses
the existing local default of 10. Suggestions require manual review before
entering an application CSV. Existing weights are never changed automatically.

Base and imported category identities have precedence over local supplements;
copying an existing word to a new category cannot correct its runtime weight.
Any reviewed correction must edit the authoritative CSV and retain an explicit
before/after record. A zero count or genre imbalance alone is not grounds for
removing or downweighting a word. Prior explicit user adjustments remain intact.

After adopting reviewed changes, regenerate/check runtime resources and run the
vocabulary tests, shared Swift tests and Debug build as documented in
[Chinese maintenance](../docs/CHINESE_VOCABULARY.md). Automated checks establish
data integrity and exercised behavior, not general accuracy or live host
compatibility. No installation is needed for this offline review.
