# SI ranking evaluation

The separate [LambdaRank starter experiment](lambdarank/README.md) has editable
training and validation data; it checks overlap against this frozen test suite
and does not train or tune on its answers.

This directory contains one authored [220-query ranking test set](ranking/test.jsonl).

| File | Purpose |
| --- | --- |
| `ranking/test.jsonl` | Exact source spelling and intended accepted outputs, one query per line |
| `ranking/manifest.json` | Seed, counts, categories, provenance, limitations and file/generator SHA-256 |

All cases enable Chinese and English with empty personal state and no preceding
context. References are exact complete outputs; a matching prefix is not a hit.
The data contains no frozen candidates. Generate candidates with the engine
version being evaluated, keep missing targets in the denominator and distinguish
retrieval from ranking. Do not insert reference answers into candidate pools.

## Contents and provenance

- 22 documented regression queries, including continuous/separated spellings of
  `找几处句子`, `二倍做多`, `我想按照`, `和上次比`, `现在添加字幕`,
  `词出现的`, `语料`, `泰国`, `零`, `吗` and a full-sentence query.
  Page regressions retain only `第二页` and `第七页`, without spelling duplicates.
- One explicitly requested technical term: `houxuanchi → 候选池`.
- One explicitly requested sentence: `dajiaxiazhouxiangqubeihaiguzhen → 大家下周想去北海古镇`.
- Six explicitly requested English hard cases: `goon → go on`, `into`, `also`,
  `maybe`, `cannot` and `myself`.
- Four other ordinal examples: `第十一章`, `第三节`, `第四段`, `第六行`.
- Two source encodings (`ü` and `u:`) of the single target `我想买绿色背包`.
- Two instances of each of 36 Chinese sentence structures (72 total), two
  continuous-English examples, and two of each of five mixed structures (10 total).
- 100 authored short Chinese queries of four to eight characters, with 60
  homophone cases such as `收拾行李` and `试戴首饰`, 25 cross-word segmentation
  cases such as `用心学习` (`用心 / 学习` and `心血`), and 15 syllable-boundary
  cases such as `方案已经定了` (`fang'an` and `fan'gan`). Each note identifies
  a competing reading for a span of the input.

The initial 5,000-row draft was replaced at the user's request because slot and
number substitutions overwhelmed distinct coverage. The current compact-v5 identity
contains 131 families, **at most two cases per family**. Changing a subject, time,
object, tool name or ordinal does not justify a long series. The generator and
validator enforce this cap; there is no quota-filling loop. Future additions
should introduce distinct problems rather than restore combinatorial padding.

The generator's authored short cases, text/reading fragments and grammar-compatible
slot pools are SI-authored material under GPL-3.0-only. No retired eval
rows, language-model outputs, training CSVs, corpus sentences, host text, private
history or personal phrases supply these generated targets. The one-time
replacement audit found zero exact input/reference-pair overlaps with the retired
public eval suites for the original 120 rows. The maintained dictionary was used
to verify character readings and the competing readings documented for the new
short cases. No candidate reachability filter was applied.

Each row has `id`, `input`, `references`, `category`, `origin`, `family`,
`languages` and `context`. Chinese-only rows also retain canonical per-character
`syllables` for reviewing spelling alignment. Source aliases and apostrophes
remain exact bytes in `input`. References preserve English casing and mixed
language boundary spaces. `family` identifies a shared template or regression;
it is not a claim of independent sampling. Inspect category/family results as
well as the overall result.

This is a single synthetic regression test set, with AI-assisted labels and no
independent human annotation or model-corpus overlap audit. Its 220 rows are
representative synthetic cases, not independent natural typing observations.
Ambiguous cases record intended targets; other homophones may also be valid.
Do not train on it or select model/ranking settings against its answers. There
is no fresh heldout generalization claim, and no runtime accuracy is measured
merely by validating the data. It does not test host events, learning or latency.

## Validate and evaluate

```sh
python3 scripts/generate_ranking_eval.py --check
python3 -m unittest discover -s Tests/RankingEvalTests -v

# Reproduce into a new directory; existing test bytes are never overwritten.
python3 scripts/generate_ranking_eval.py --output /tmp/si-ranking-reproduction

# Blind requests omit references, categories, syllables and target notes.
python3 scripts/ranking_eval.py requests --output /tmp/si-ranking-requests.jsonl
si_rust="$PWD/.build/rust-app/eval"
export SI_ENGINE_RESOURCE_DIRECTORY="$si_rust/SIEngine"
bash scripts/prepare-rust-app.sh --fixtures "$si_rust" "$SI_ENGINE_RESOURCE_DIRECTORY"
swift build --scratch-path .build/swift --configuration release \
  -Xlinker "-L$si_rust" --product SICandidateExport
.build/swift/release/SICandidateExport < /tmp/si-ranking-requests.jsonl > /tmp/si-ranking-predictions.jsonl
python3 scripts/ranking_eval.py score --predictions /tmp/si-ranking-predictions.jsonl \
  --output /tmp/si-ranking-report.json
```

The exporter emits the first 32 eligible complete nonliteral,
noncompletion candidates from dictionary-only bilingual Rust engine ranking.
It uses the resource directory prepared by the command above. The scorer reports **exported-pool
recall**, Top-1/Top-5 and MRR for that explicit protocol, not full-engine recall
or native-window accuracy. Empty/missing-gold pools stay in the denominator.
Reports bind the dataset and prediction hashes; separately record the exact code
revision, dirty patch, exporter binary and dictionary/model identities with any
experiment. No old model adapter, frozen-pool comparison or `python -m eval`
command remains. Model-specific training and token-loss tools stay under `llm/`.
