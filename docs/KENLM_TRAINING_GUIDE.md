# KenLM training and candidate ranking guide

This guide records SI's training and ranking workflow and explains how to reuse
it for another corpus, language or model. Commands run from the repository root.
The command interfaces and production preset were checked on November 8, 2026.
Historical measurements describe their recorded corpus and decoder versions.
Changing a vocabulary, reading generator or search budget requires a new run.

The experiment journal contains the complete historical tables and command
records. The corpus guide describes current raw-text preparation, which has
changed since the first model was trained.
[Experiment journal](../README_kenlm_train.md), [current corpus preparation](../corpus/README.md),
[frozen six-source tokenization record](../corpus/KENLM_DATA.md).

## 1. Separate the decisions and artifacts

| Decision | Data and artifact | Selection evidence |
| --- | --- | --- |
| Segmentation and cleaning | Versioned tokenized text and mapping | Retention checks, examples, vocabulary and replacement statistics |
| LM order, pruning and packing | Train-only model | Validation PPL, binary size, n-gram counts and runtime measurements |
| Candidate ranking weights | Train-only model and frozen decoder queries | Development Top-1, coverage controls, English regression and latency |
| Final model | Approved settings refit on train followed by heldout | Load, metadata and synthetic scoring sanity checks |
| App delivery | Verified final binary inside the signed app | Extracted installer payload and fresh-install loading |

Freeze model selection before the full-data fit. Keep the train-only model for
subsequent ranking experiments and preserve its complete input and command
history. The full-data model has seen the original heldout population.

In this project, the original LM heldout also served as validation for selecting
the LM configuration. A later dev/test split of queries from it freezes ranking
weight evaluation, but does not create a wholly independent end-to-end model
test. For a new study, reserve a separate source-group test population before
model selection. Record document, dialogue and near-duplicate overlap checks
in addition to exact-line checks.

## 2. Record inputs before processing

For each source, retain its origin, version, license notices, archive SHA-256
and extraction rules. Record code revision and any uncommitted experiment
patch, dictionary hashes, Python/Unicode versions, KenLM archive and executable
hashes, seed and hardware. Use a fresh output directory for changed inputs.

Our model used LCCC, mC4, Kubernetes, TensorFlow, MDN, SI, Dialogue.
Their individual terms and pinned versions remain in the corpus source lock.
Language data, personal phrases and user history have separate ownership and
consent boundaries. A private export is not automatic authorization for training
or redistribution.
[Pinned sources](../corpus/chinese/sources.lock.json), [data policy](../CONTRIBUTING.md#local-corpus-and-model-artifacts).

Check extraction before tuning. An earlier pipeline split at non-Han
boundaries and retained 4–96-character fragments, losing numbers and sentence
structure. The trained word-only v2 model instead used complete raw-derived
text lines before tokenization. Preserve this distinction in provenance.

The current extractor writes OpenCC-t2s raw-text-v2 and supports additional local
sources. The frozen training corpus used raw-text-v1. The current multi-source
tokenizer still defaults to the retired raw-text-v1 path and accepts the pinned
six-source IDs. Its defaults are not an end-to-end command for the new local
sources. Use explicit input paths and validate source compatibility before a
new multi-source run.

## 3. Tokenize with a versioned vocabulary

Our Chinese tokenizer performs NFKC normalization, removes control/invisible
characters, splits sentences at configured punctuation and retains punctuation.
It separates Han spans, English words, numbers and individual symbols. Han
spans use dictionary unigram Viterbi segmentation, with a low-scoring unknown
single-character fallback. English is lowercased. Sentences over 100 output
tokens are dropped. Output is UTF-8, one sentence per line, with single spaces
between tokens and no empty lines.

The segmentation vocabulary comes from flat Chinese word CSVs. Nested
`chinese/phrase/` data is excluded. A word independently present in a flat
word file remains eligible even if it also occurs in a phrase collection.
Tokenizer counts come from the retained corpus-frequency reference, with an
explicit pseudocount for unobserved words. Input-method ranking weights are
transformed ranking values and must not be treated as corpus counts.

For a new compatible Chinese text file, the shared tokenizer has this interface.
The output path must be new. This example does not acquire or extract sources.

```sh
python3 corpus/tokenize_unigram.py \
  --input /path/to/new-source.txt \
  --output /path/to/new-run/tokenized.txt \
  --dictionary /path/to/frozen/frequencies.csv \
  --workers 4 --chunk-lines 1000 --chunk-bytes 1048576
```

Record input lines, empty lines, candidate sentences, retained tokens and
over-length exclusions. Audit examples containing punctuation, numbers,
English and long words. Source-retention checks should establish that losses
match declared filters. For another language, replace the Han-specific
segmentation and reading generation while retaining these output contracts.
[Tokenizer](../corpus/tokenize_unigram.py), [word vocabulary builder](../corpus/build_word_dictionary.py).

## 4. Create and freeze the split once

The first model run retained the first occurrence of each exact tokenized line,
then assigned 1,000-line blocks using SHA-256 and seed 20261105. Approximately
2% of blocks went to heldout. It verified internal uniqueness and no shared
line hashes. Its hash set scales with the number of unique lines.

| Frozen population | Lines | Tokens, excluding added EOS |
| --- | ---: | ---: |
| Tokenized input | 59,811,874 | 871,659,206 |
| Deduplicated input | 46,966,862 | 809,131,778 |
| Train | 46,077,862 | 793,546,051 |
| Heldout | 889,000 | 15,585,727 |

The initial selection script accepts a new input and run directory. After
preparation, use its existing train and heldout for every comparison in that
run. Keep the manifest and audit evidence with the files.

```sh
si_run=/path/to/new-run/selection
si_input=/path/to/new-run/tokenized.txt
corpus/.venv/bin/python corpus/kenlm_train.py prepare \
  --input "$si_input" --run "$si_run" --seed 20261105
corpus/.venv/bin/python corpus/kenlm_train.py audit --run "$si_run"
```

For another corpus, choose the grouping policy before running this step.
Exact-line disjointness alone does not establish document or conversation
independence.

## 5. Freeze the cleaning contract

Cleaning occurs after tokenization and never re-splits the frozen files.
The Python contract and Swift implementation share test vectors.

| Order | Rule |
| --- | --- |
| 1 | Delete the entire line containing U+FFFD, 锟斤拷, 烫烫烫 or 屯屯屯 |
| 2 | Replace a numeric token matching the full numeric grammar with `<num>` |
| 3 | Replace a token longer than 32 Unicode scalars with `<oov>` |
| 4 | Apply the selected rare-token mapping |

The numeric grammar is
`[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?`.
It uses Unicode decimal digits and ASCII signs, dot and exponent markers.
Length is Unicode scalar count, not grapheme count or UTF-16 length.

clean1 uses the first three rules. clean2 additionally maps an unprotected
token with train count below 5 to `<oov>`; clean3 uses below 20. Count
surviving base-cleaned train data and use the same mapping for heldout.
Dictionary protection is the exact, case-sensitive text union of the flat
Chinese and English vocabulary CSVs. Phrase subdirectories are excluded.

Report deleted lines, retained lines/tokens, vocabulary size and replacement
counts and shares for each split. Preserve the protected vocabulary and full
mapping. Cleaning can make different lines identical, including across splits.
Our experiments retained their membership and performed no further deduplication.

`<num>` and `<oov>` are ordinary model vocabulary items. They differ from
KenLM's reserved `<unk>`, `<s>` and `</s>`. A protected dictionary word absent
from training can still be a true query OOV. Native scoring maps missing model
indices to the ordinary `<oov>` entry.
[Python contract](../scripts/kenlm_cleaning.py), [portable vectors](../Tests/KenLMTests/cleaning_vectors.json),
[Swift contract](../mac/SI/Core/KenLMCleaning.swift).

## 6. Compare train-only language models

Build the pinned KenLM tools, then run small functional smoke fits before
complete train-split fits. Our smoke population was the first 100,000 train
lines, with at most 10,000 heldout lines for query checks.

```sh
bash corpus/kenlm/build_tools.sh
corpus/.venv/bin/python corpus/kenlm_train.py smoke --run "$si_run"
corpus/.venv/bin/python corpus/kenlm_train.py compare --run "$si_run"
```

The current `compare` and `report` commands update the first-round section
of the shared `README_kenlm_train.md` as well as run-local results. For a new
study, review that report destination when adapting the script and retain the
preceding journal. A fresh `--run` directory does not isolate that Markdown
side effect.

The historical progression was broader order/pruning comparison, stronger
pruning and quantization controls, then clean1/2/3 vocabulary experiments.

| Round | Main comparison | What we learned |
| --- | --- | --- |
| Initial | Orders 3–5 and several pruning levels | Lower PPL could require multi-GiB binaries |
| Second | More pruning, quantized versus unquantized trie | Packing and pruning need separate measurements |
| Third | clean1/2/3 and two order-4 pruning settings | Freeze vocabulary transformations before interpreting PPL |
| Packing control | Same clean2 ARPA, with and without `-a 22` | Binary size fell from 520.54 to 398.88 MiB with unchanged reported PPL |

The selected deployable configuration was clean2, order 4, prune
`0 1 2 3`, quantized trie `-a 22 -q 8 -b 8`. Its train-only PPL including
OOV was 154.002863. The larger clean2 prune `0 0 1 2` model had PPL
140.631962 and a much larger binary. This was a size/quality decision.

For a new run with already cleaned train and heldout, the tool commands are
generic. Choose a new directory and preserve both logs.

```sh
si_tools=corpus/.cache/kenlm-build/bin
si_model=/path/to/new-run/order4
mkdir -p "$si_model"
"$si_tools/lmplz" -o 4 --prune 0 1 2 3 -S 40% -T /tmp \
  < /path/to/new-run/clean2/train.txt > "$si_model/model.arpa" \
  2> "$si_model/lmplz.log"
"$si_tools/build_binary" -a 22 -q 8 -b 8 trie \
  "$si_model/model.arpa" "$si_model/model.trie" 2> "$si_model/build.log"
"$si_tools/query" -v sentence -v summary "$si_model/model.trie" \
  < /path/to/new-run/clean2/heldout.txt \
  > "$si_model/query.out" 2> "$si_model/query.log"
```

If discount estimation fails, preserve the failure and record an explicit
retry with `--discount_fallback`. The recorded final fit did not need it.
Sorting memory `-S 40%` does not bound total RSS. Budget for temporary files,
ARPA output, both binaries and packaging copies.

For every model, report PPL including/excluding true OOV, OOV counts, all ARPA
header n-gram counts, binary bytes and training/query time. Compare PPL only
under the same tokenization and vocabulary mapping. Query token totals include
EOS, so explain their difference from corpus token counts.

Measure startup/scoring separately from decoder latency. Record wall time,
CPU and RSS for identical query input under normal and lazy loading. On the
recorded Darwin build, query's RSS label was misleading and values required
byte-to-MiB conversion. Page-cache purging was denied, so first runs were
cache-uncontrolled. Lazy mapping can fault in much of the model during a full
query and does not imply a small sustained RSS.

## 7. Freeze candidate queries and measure retrieval first

Keep a train-only model, the exact compiled dictionaries and the same native
decoder for development and testing. Record model, dictionary, dataset and
decoder-code identities. The scorer sees the winning lexical derivation for
each candidate ID. Reranking operates on the emitted pool.

Our preparation split tokenized heldout lines into punctuation-delimited
clauses, selected one readable Han-only clause per eligible source line, and
sampled 20,000 clauses with seed 20261106. It generated Pinyin from each word's
highest-weight dictionary reading, with character fallback. Whole text/Pinyin
duplicates and source-clause siblings stayed in the same split.

The resulting populations were 11,997 development clauses and 8,003 test
clauses. Each supplied a whole query, a short span, and where possible paired
noninitial spans with and without explicit context. Common short spans can
repeat across splits. A 30,841-line strict subset retained the earlier
whole-line/unique-reading policy and overlaps development and test sources.
Treat it as a diagnostic control.

Count unreadable, non-Han and other exclusions and their punctuation, digit,
English and polyphonic-token incidence. Retain unreachable gold examples in
accuracy denominators. Report pool recall, shortlist Top-1/Top-5, edit error
and P50/P95 latency by query kind and gold length buckets 1–8, 9–16, 17–32, 33+.
The offline shortlist does not reproduce machine-specific font filtering.

For misses, test the native word graph before attributing a failure to ranking.
Our probe separates bounded graph reachability, lexical row truncation, hard
input/output limits and dictionary paths excluded by cut/span restrictions.
Check missing original tokens and reading compatibility separately.

In the recorded decoder, 4,237 of 8,003 clauses missed the pool. Of these,
2,105 had a path before beam/terminal selection, 1,716 lost it to the 32-row
lexical cap, 345 exceeded input length and 71 hit other cut/span restrictions.
There were no missing-word or incompatible-spelling cases in this
dictionary-generated sample. Contextual pronunciation correctness was not
independently labeled.

These counts predate the current worktree's increase to 32 terminal alternatives
per Chinese lane. They must not be quoted as measurements of that revised
decoder. A new search policy needs a new benchmark identity and recall report.

## 8. Tune ranking parameters on development data

Use bits consistently. The base decoder uses natural-log costs in some search
lanes and converts them at ranking boundaries. KenLM returns log10 scores,
which the scorer multiplies by `log2(10)`. Higher final scores rank first.

For ordinary lexical candidates, the current pool applies these deltas to its
existing presentation score. Personal/verbatim and other excluded paths retain
their existing treatment.

```text
score = existingPresentationScore
      + w_lm_zh * chineseLMBits
      + (w_freq - 1) * chineseFrequencyBits
      + (20 / ln(2) - w_wip_zh) * chineseTokenCount
      + (23 / ln(2) - w_wip_en) * englishTokenCount
```

The Chinese LM terms activate only with an available model and nonzero
Chinese LM weight. English LM has a separate parameter with default zero.
The insertion-only ablation explicitly bypasses the LM activation gate.
At zero LM weight, use the legacy English insertion cost and disable coverage
for an exact original-path control.

LM scoring starts at BOS, resets at language boundaries and scores only the
consumed lexical tokens. It adds no EOS or hypothetical suffix. Track
`lm_oov_ratio` among scored candidate tokens. The offline scorer can accept up
to three explicit preceding tokens. Production ranking reads no host-field text.

Coverage A is an independent ordering dimension. After pins and remembered
choices, whole candidates precede prefixes and longer prefix spans precede
shorter ones. Scores compete within the group. Keep exact input, source
boundaries and commits available throughout these changes.

| Parameter | Development grid or fixed setting |
| --- | --- |
| `w_freq` | 1 |
| Chinese `w_lm` | 0.05, 0.1, 0.15, 0.25, 0.5, 1, 2 |
| Chinese `w_wip` | −4, 0, 2, 4, 6, 8, 10, 12, 16, 22, 28.85 |
| Coverage A | Off and on |
| Controls | Legacy, coverage alone, insertion alone |

The expanded sweep evaluated 167 profiles. Selection maximized pooled dev
Top-1, then preferred smaller LM weight and insertion cost closest to 28.85.
Report every equal-accuracy leader before applying tie-breaks. The unique
maxima were LM weight 0.25 with cost 22 when coverage was off, and LM weight
0.25 with cost 28.85 when coverage was on. Smaller LM weights did not win.
Freeze these choices before evaluating the test queries.

Recorded whole-clause Top-1/Top-5 moved from 30.33%/43.33% to 34.40%/45.57%
with LM plus coverage. Pool recall was only 47.06%. On paired noninitial spans,
gold context moved combined Top-1 from 47.56% to 50.56%. That experiment does
not establish the accuracy of a live context reader.

## 9. Audit and tune English independently

A Chinese-only LM can still affect English through cross-language competition.
Test both providers together as well as English alone. Our regression sampled
100 words in each of five dictionary-weight bands and generated whole inputs
and proper prefixes of at least three letters.

Audit every alphabetic whole word that can be formed by two dictionary words.
Record whole/left, whole/right and whole/(left × right) weight ratios and the
actual first candidate. Rank distinct words by their most extreme product ratio
for a 200-item review list. These ratios are descriptive because spelling and
language costs also affect ordering.

The audit found 33,760 words and 39,476 splits. In English-only mode, 377 words
failed Top-1, including 109 split winners. The 200-item list contained 105 of
those split winners. Report this pattern before changing dictionary weights.

Generate common-word guards from lowercase alphabetic words of at least four
letters with weight strictly above 1,000. Our set had 2,438 words, split by
word-key SHA-256 into 1,477 dev and 961 validation words. Apply the same split
to whole/prefix families in the original English sample.

Tune absolute English per-word cost separately, with coverage on and both LM
weights zero. The grid was 24, 28, 30, 32, the legacy 23/ln(2), 34, 35, 36, 37,
38, 40, 42, 46, 50 bits. Selection maximized the equally weighted mean dev
Top-1 over whole words, prefixes and guards, then preferred the closest cost
to legacy on ties. The unique winner was 28 bits.

Validate the combined Chinese and English choices after independent selection.
With Chinese LM plus coverage, English whole Top-1 fell from 99.00% to 98.20%
when switching to 28 bits, while whole Top-5 rose to 100% and prefix Top-5 rose
from 73.40% to 75.40%. Preserve that tradeoff in the decision record.
`goon → go on` passed, while `cannot → cannot` still lost to `can not`.
The four other authored whole-word guards passed. These probes supplement
the generated set and do not justify word-specific score patches.

## 10. Replay the recorded ranking study

These commands target the existing Chinese experiment. Use a new results
directory and the frozen query directory. Creating a new dataset is a separate
step using `scripts/prepare_kenlm_ranking.py OUTPUT --count 20000`.

```sh
si_results=.build/kenlm-ranking-new-study
si_dataset=.build/kenlm-ranking/dataset
si_model=.build/kenlm-round3/models/clean2/p0123-a22/model.trie
mkdir -p "$si_results"
swift build -c release -debug-info-format none \
  --scratch-path "$si_results/build" --disable-sandbox --product SIBenchmark
si_cli="$(swift build -c release --scratch-path "$si_results/build" --show-bin-path)/SIBenchmark"

"$si_cli" --kenlm recall "$si_model" "$si_dataset" > "$si_results/recall-probe.json"
corpus/.venv/bin/python scripts/diagnose_kenlm_ranking.py recall \
  "$si_dataset" "$si_results/recall-probe.json" "$si_results"
"$si_cli" --kenlm tune "$si_model" "$si_dataset" > "$si_results/tuning.json"
"$si_cli" --kenlm test "$si_model" "$si_dataset" "$si_results/tuning.json" > "$si_results/test.json"
"$si_cli" --kenlm strict "$si_model" "$si_dataset" "$si_results/tuning.json" > "$si_results/strict.json"

corpus/.venv/bin/python scripts/diagnose_kenlm_ranking.py english "$si_dataset" "$si_results"
"$si_cli" --english-ranking audit "$si_results/english-audit.jsonl" > "$si_results/english-audit.json"
corpus/.venv/bin/python scripts/diagnose_kenlm_ranking.py summarize-english "$si_results"
"$si_cli" --english-ranking grid "$si_dataset/english.jsonl" \
  "$si_results/english-guards.jsonl" > "$si_results/english-grid.json"
"$si_cli" --kenlm english-final "$si_model" "$si_dataset" \
  "$si_results/english-grid.json" "$si_results/tuning.json" > "$si_results/english.json"
"$si_cli" --kenlm hard "$si_model" "$si_dataset" eval/ranking/hard-cases.tsv \
  "$si_results/english-grid.json" "$si_results/tuning.json" > "$si_results/hard.json"
```

Feature export through `SICandidateExport --features TRAIN_ONLY_MODEL` reads
explicit JSONL requests and writes absolute and within-span relative features.
It uses the same candidate pool as the app.

The model hash guard currently admits only the recorded train-only artifact.
For a new model, review the expected identity in `KenLMModel.openBenchmark`,
create a new dataset identity and preserve old results. Round-two,
round-three, final-fit and query-preparation scripts also contain Chinese
experiment paths and contract assumptions. They need an explicit adaptation
before serving another population. A different CLI filename alone does not
make them generic trainers.
[Benchmark entry point](../Tools/SIBenchmark/KenLMRankingBenchmark.swift),
[English grid](../Tools/SIBenchmark/EnglishRankingBenchmark.swift),
[model identity guard](../mac/SI/Core/KenLMModel.swift).

## 11. Fit the final model after approval

Concatenate original train then heldout, recalculate cleaning frequencies on
the surviving full population, freeze the complete new mapping, and apply
clean2 once. Preserve the originals and train-only models. Perform no new
deduplication or splitting.

Our final cleaned text had 46,943,793 lines and 808,294,186 tokens.
Its vocabulary had 1,407,621 types before three KenLM special entries.
The final model was 405.24 MiB. The matching train-only binary was 398.88 MiB.
The final four-gram count grew 2.128%, a sanity observation rather than a
forced acceptance threshold.

```sh
si_final=/path/to/new-final-run
mkdir -p "$si_final"
"$si_tools/lmplz" -o 4 --prune 0 1 2 3 -S 40% -T /tmp \
  < /path/to/new-final-run/full.clean2.txt > "$si_final/final.arpa" \
  2> "$si_final/lmplz.log"
"$si_tools/build_binary" -a 22 -q 8 -b 8 trie \
  "$si_final/final.arpa" "$si_final/final.bin"
```

The repository's `scripts/kenlm_final.py all` performs the recorded preparation,
fit, sanity and report stages, but fixes its population and output to the
existing Chinese run. For new data, adapt those pins before invoking it.

Check ordinary `<num>` and `<oov>` entries, default/lazy loading and finite
query scores. Our synthetic sanity suite compared 20 natural sentences with
20 token-reversed controls. All natural sentences won. Keep the authored
examples and raw scores, and label this as a sanity check. There is no
heldout PPL for a model trained on that heldout.

## 12. Validate integration and ship the model

Persist model SHA-256 and bytes, build time, KenLM source/tool identity,
cleaning version/module/vector hashes, dictionary and corpus hashes, mapping
identity, vocabulary/n-gram counts and exact commands. The recorded source
archive contains revision `b32c19389737a5def8bbc4623de809ced3091187`.
The historical final metadata retained an earlier null Git-revision field.

Keep cleaning vectors aligned between Python and Swift. Verify zero-weight
parity for IDs, score bit patterns, shortlist, committed bytes and exact
remaining input. After changing core behavior, run the full Swift suite and
Debug build, and the Release build for distribution. Test secure input,
missing-model fallback, stale workers and prefix confirmation. Live host
checks remain necessary.

The production preset is Chinese LM 0.25, Chinese insertion 28.85 bits,
English insertion 28 bits, English LM zero and coverage A on. It is applied
by `LanguageSettings.productionRanking`; the reusable core retains legacy
defaults for explicit controls. Full background results use the model.
Previews and immediate confirmation fallback use dictionary scores.

Current release and local installation select the raw-text-v2 no-Wikipedia
`0012` full-data model under
`.build/kenlm-raw-text-v2-no-wikipedia-p0012/final/` (`final.bin` and
`final.meta.json`); see [the current model record](KENLM_MODEL.md). The earlier
`.build/kenlm-final` population remains a historical artifact. Packaging
verifies the binary hash, stages the model,
compatibility metadata and notices under `SI.app/Contents/Resources/KenLM/`,
then signs that app. Both the installer in the DMG and the Sparkle ZIP carry
the model. The runtime prefers this resource and supports the versioned
App Support installation as a source-build fallback.

Verify the extracted installer app, embedded hash/size and loading with no
App Support model. A query library linked into the executable is not evidence
that the release carries its model. Keep binaries, ARPAs, corpora and generated
reports Git-ignored. Recheck source attribution and redistribution terms for
every new population before preparing distribution.
[Release procedure](RELEASING.md), [integration checks](TESTING.md#production-kenlm-ranking),
[production preset](../mac/SI/Settings/LanguageSettings.swift).

## Record template for the next run

Copy this table into the new run's report and attach the machine-readable
manifests and command logs.

| Field | Required record |
| --- | --- |
| Identity | Run name, date, code revision/patch and language/domain |
| Inputs | Source versions, rights/notices, raw/extracted/dictionary hashes |
| Preparation | Normalization, tokenizer, exclusions and source-retention results |
| Populations | Split/group policy, seed, overlap audit and file hashes |
| Cleaning | Rules, Unicode version, protection set and frozen mapping |
| LM comparison | Configs, PPL/OOV, bytes, n-gram counts and runtime |
| Retrieval | Pool/shortlist recall, length buckets, categories and examples |
| Ranking | Grid, objective, controls, all co-leaders and selected settings |
| Validation | Frozen Top-1/Top-5, edits, latency, English/mixed regression and failures |
| Final fit | Approved config, full-data mapping, model hash and sanity results |
| Delivery | Embedded artifact verification, code signature and fresh-install checks |
| Limits | Evaluation overlap, unlabeled cases, unresolved regressions and host checks |
