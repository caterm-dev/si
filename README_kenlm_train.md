# KenLM experiments and final model build

For a reusable workflow and lessons from these runs, see
[the training and candidate ranking guide](docs/KENLM_TRAINING_GUIDE.md).

The offline training experiments use the completed word-side-only tokenization at
`corpus/chinese/generated/kenlm-words-v2/kenlm-input.txt` (SHA-256
`92660454982b99a22c815871b3345ed664cd04493ae8c2471aa781540f470f47`).
Its vocabulary comes only from flat Chinese word CSVs; `chinese/phrase/` is
excluded as a vocabulary source. Source data terms and attribution remain with
the input corpus. See [the development ranking experiment](#development-kenlm-ranking)
for native integration and heldout ranking results.

The first three rounds below record **train-split comparison models**. Their
statements that final retraining was not performed describe those historical
experiments. The separately authorized final full-data clean2 build uses
[scripts/kenlm_final.py](scripts/kenlm_final.py), with artifacts under
`.build/kenlm-final/`; its commands, provenance and acceptance results are recorded
in [the full-data build section](#final-full-data-clean2-build). The original
comparison script has no automatic final-fit stage.

## Model uses

Both artifacts use clean2, order 4, pruning `0 1 2 3`, and an 8-bit probability
and backoff trie with `-a 22`. The training population determines their use.

| Role | Local artifact | SHA-256 |
| --- | --- | --- |
| App model | `.build/kenlm-final/final.bin` | `b8ff26637fa93e5d9a2bc4aacd9e22e00b4d30d421ce1d158f7e6cb8889ca286` |
| Ranking benchmark and weight tuning | `.build/kenlm-round3/models/clean2/p0123-a22/model.trie` | `0083776ec5acaf9c818ac7cf1eedf9cd955d9c2eb7cbc734cd07bb7e33e20605` |

The app model uses the combined train and former heldout population, with
clean2 frequencies recalculated on the combined data. Its companion manifest
is `.build/kenlm-final/final.meta.json`. Exclude this artifact from heldout
ranking evaluation and weight selection.

The benchmark model uses only the original train split and its clean2
frequencies. Its `result.json` records the binary hash. The command journal in
`p0123` records estimation from `data/clean2/train.txt`, and the journal in
`p0123-a22` records conversion of that same ARPA. Use this binary for
heldout-derived pinyin benchmarks, weight tuning and LM feature extraction on
those examples.

## Tools and source pin

Python 3.12+ and the standard library suffice for the pipeline. KenLM is built
locally from its author's official source archive. The complete archive pin,
binary hashes, compiler/dependency versions and build commands are in
[the tool lock](corpus/kenlm/source.lock.json). Full upstream license notices are
retained beside that lock. SI links a [query-only library](Vendor/SIKenLM/README.md)
for runtime ranking. Release packages stage the model from local build artifacts.

```sh
# macOS build dependencies (the current machine already had CMake):
HOMEBREW_NO_AUTO_UPDATE=1 brew install cmake boost eigen
# Verify the pinned cached archive, or explicitly download it if absent:
bash corpus/kenlm/build_tools.sh
```

Official archive: `https://kheafield.com/code/kenlm.tar.gz`.
SHA-256: `6bb66b6c17f6d23907bd6258ee585328b3e5f5f2b201d41c5f6bd0c390c2c913`.
The author URL is mutable; a changed archive is rejected rather than adopted.
Retain the verified local archive for exact source reproduction. Optional Eigen3
interpolation is not built with the installed Eigen 5 and is not required by
these three tools. No upstream source changes were needed.

The actual CMake invocation is:

```sh
cmake -S corpus/.cache/kenlm-src/kenlm -B corpus/.cache/kenlm-build \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DBUILD_TESTING=OFF
cmake --build corpus/.cache/kenlm-build --target lmplz build_binary query -j 6
```

## Reproduce the experiment

Run from the repository root. All stages use a fresh immutable output directory,
or verify matching completed artifacts before resuming. Failed-stage artifacts
and command/error logs are retained under `failed-*` for diagnosis.

```sh
corpus/.venv/bin/python corpus/kenlm_train.py prepare \
  --input corpus/chinese/generated/kenlm-words-v2/kenlm-input.txt \
  --run corpus/chinese/generated/kenlm-selection-v1 --seed 20261105
corpus/.venv/bin/python corpus/kenlm_train.py smoke \
  --run corpus/chinese/generated/kenlm-selection-v1 \
  --tools corpus/.cache/kenlm-build/bin
corpus/.venv/bin/python corpus/kenlm_train.py compare \
  --run corpus/chinese/generated/kenlm-selection-v1 \
  --tools corpus/.cache/kenlm-build/bin
corpus/.venv/bin/python corpus/kenlm_train.py audit \
  --run corpus/chinese/generated/kenlm-selection-v1
corpus/.venv/bin/python corpus/kenlm_train.py report \
  --run corpus/chinese/generated/kenlm-selection-v1
```

`compare` itself checks/runs all four smoke tests before starting any complete
train-split model, so the separate `smoke` invocation is optional. Repeated runs
verify matching input, option and executable hashes instead of retraining valid
completed models. A different input, seed or options need a new `--run` path.
Model-level `commands.jsonl` retains exact argv, stdin/stdout/stderr paths,
exit status and monotonic elapsed time for every invocation, including retries.
Commands contain staging paths actually used during execution; the stage is
renamed to its final configuration folder after success.

## Deduplication and block split

Input is read one UTF-8 line at a time. A SHA-256 line-hash set retains only the
first occurrence, preserving order. Full sentence strings are not retained in
memory. A hash set intentionally scales with unique-line count; this is not a
constant-memory deduplicator. Input tokens/spacing are validated, not re-cleaned.
Generated LF lines are hashed consistently, including the trailing LF.

After deduplication, number lines from zero and assign blocks of **1,000 lines**.
The last block may be shorter. **Fixed seed: `20261105`**. For zero-based block
`b`, compute SHA-256 over ASCII `kenlm-block-v1:20261105:b`, interpret the first
eight digest bytes as an unsigned big-endian integer, then take modulo 10,000.
A result below **200** selects heldout; otherwise select train. Python's
randomized `hash()` is never used. No rebalancing forces exactly 2%.

The independent verifier rereads both outputs, checks internal uniqueness and
rejects any train/heldout hash intersection. A separate `audit` stage
reconstructs all block routes from the deduplicated stream, compares the actual
train/heldout bytes, validates output checksums, and checks both smoke prefixes. Preparation keeps
`deduplicated.txt`, `train.txt`, `heldout.txt` and a manifest of counts/hashes.
Word counts count space-separated input tokens, including punctuation, without
added sentence markers. SHA-256 supplies the requested practical line-hash set.
No identical lines cross the split; this does not establish near-duplicate or
whole-document isolation. Heldout is validation data for configuration choice,
not an independent final test set.

Measured preparation:

| Item | Lines | Tokens |
| --- | ---: | ---: |
| Original input | 59,811,874 | 871,659,206 |
| Deduplicated | 46,966,862 | 809,131,778 |
| train.txt | 46,077,862 | 793,546,051 |
| heldout.txt | 889,000 | 15,585,727 |

Removed **12,845,012** duplicate lines. Heldout represents **1.8928239234%** of
unique lines. SHA-256 verification found no internal or shared duplicate lines.
The split manifest records the full input/output hashes and exact counters.

## Training, quantization and evaluation

All four smoke models use exactly the first **100,000 lines of train.txt**.
For a quick functional query check they use the first at most **10,000 heldout
lines**. All smoke stages must pass before any complete train-split fit.
Smoke perplexities are not used to choose the configuration.

The complete comparison uses the following commands (substitute each model's
output path). Jobs run sequentially with **`-S 40% -T /tmp`**. This machine has
36 GiB physical memory, so the requested sorting budget is 14.4 GiB; this is a
buffer budget, not a promise about total process RSS. Temporary disk and ARPA
space are also needed. The four configurations are unchanged from the request:

```sh
kenlm_bin=corpus/.cache/kenlm-build/bin
kenlm_run=corpus/chinese/generated/kenlm-selection-v1
mkdir -p "$kenlm_run/manual"
"$kenlm_bin/lmplz" -o 3 -S 40% -T /tmp --prune 0 0 1 < "$kenlm_run/data/train.txt" > "$kenlm_run/manual/o3.arpa"
"$kenlm_bin/lmplz" -o 4 -S 40% -T /tmp --prune 0 0 1 2 < "$kenlm_run/data/train.txt" > "$kenlm_run/manual/o4a.arpa"
"$kenlm_bin/lmplz" -o 4 -S 40% -T /tmp --prune 0 0 0 1 < "$kenlm_run/data/train.txt" > "$kenlm_run/manual/o4b.arpa"
"$kenlm_bin/lmplz" -o 5 -S 40% -T /tmp --prune 0 0 1 1 2 < "$kenlm_run/data/train.txt" > "$kenlm_run/manual/o5.arpa"
for kenlm_config in o3 o4a o4b o5; do
  "$kenlm_bin/build_binary" -S 40% -T /tmp -q 8 -b 8 trie \
    "$kenlm_run/manual/$kenlm_config.arpa" "$kenlm_run/manual/$kenlm_config.trie"
  "$kenlm_bin/query" -v summary "$kenlm_run/manual/$kenlm_config.trie" \
    < "$kenlm_run/data/heldout.txt" > "$kenlm_run/manual/$kenlm_config.query.txt"
done
```

The optional `-a` pointer-compression option is not supplied. All four binaries
use exactly 8 probability bits and 8 backoff bits in trie format. If estimation
reports a Kneser-Ney discount failure, the script retries once with the same
parameters plus `--discount_fallback`, preserving both attempts and recording
whether fallback was used. Other failures do not authorize changing pruning,
order or corpus size. Pruning semantics follow the
[official estimation documentation](https://kheafield.com/code/kenlm/estimation/).

Evaluation queries the quantized **binary**, not its ARPA. `-v summary` avoids
huge per-word output. Normal sentence context is retained: `query` adds its own
BOS/EOS handling, and its scored token count includes one EOS per input line.
The full heldout query must therefore score **16,474,727 tokens**. The script
validates this coverage against the actual evaluation file. PPL including OOVs,
PPL excluding OOVs and OOV count are copied from KenLM's aggregate summary.

Each configuration retains the trie, raw query summary, estimation/build/query
logs, invocation journal, n-gram counts, hashes and measured timings. A successful
ARPA intermediate is deleted only after binary construction and evaluation
succeed, keeping disk requirements manageable. Training time is reported both
as `lmplz` time (including any failed discount attempt) and as total estimation
plus binary construction; query time is separate. Binary size is actual bytes,
with MiB defined as 1,048,576 bytes.

The recommendation rule is explicit: among models within **1%** of the best
including-OOV heldout perplexity, prefer the smallest trie; use total training
time to break exact size ties. Excluding-OOV PPL and OOV counts remain visible.
This is a size/validation tradeoff for configuration selection, not a claim of
production input-method accuracy.

## Measured comparison

<!-- KENLM_RESULTS_BEGIN -->
| Config | Order / prune | PPL incl. OOV | PPL excl. OOV | OOV tokens | Trie MiB | lmplz seconds | Binary seconds | Total train seconds |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| o3 | 3 / 0 0 1 | 204.923725 | 197.906026 | 38,678 | 921.16 | 218.10 | 73.35 | 291.45 |
| o4a | 4 / 0 0 1 2 | 178.021262 | 171.894916 | 38,678 | 1249.88 | 289.09 | 89.71 | 378.80 |
| o4b | 4 / 0 0 0 1 | 164.026023 | 158.310917 | 38,678 | 3074.68 | 327.69 | 271.92 | 599.61 |
| o5 | 5 / 0 0 1 1 2 | 169.470872 | 163.621169 | 38,678 | 1663.70 | 338.82 | 129.56 | 468.38 |

Recommendation: **o4b**. Its including-OOV PPL is 0.000% above the best; it is the smallest trie satisfying the explicit 1% tolerance.

All four score 889,000 heldout lines and 16,474,727 tokens including EOS. OOV counts agree. Values are measured from quantized trie binaries.

Final combined-data retraining: **not run**, pending the user's configuration confirmation.
<!-- KENLM_RESULTS_END -->

The derived data/models stay local and Git-ignored. Final combined-data fitting
is not part of this run and will wait for the user's explicit choice.

## Validation record

All 65 corpus-tool unit tests, all 443 shared Swift tests and the Debug app
build passed. The final audit verified the original input checksum, all 46,967
block routes across 46,966,862 unique lines, both smoke-prefix hashes, all eight
model hashes and raw query summaries, the exact requested command options,
complete training token counts, full heldout query coverage and actual
smoke-before-full execution order. The measured selection and checks are retained
in [the selection snapshot](corpus/kenlm/selection-v1.snapshot.json).

## Second-round protocol

The existing `data/train.txt` and `data/heldout.txt` are opened read-only. Their
SHA-256, byte length, modification time and inode are pinned before and checked
after the experiment. There is no preparation, deduplication or split operation
in this round. All new outputs live under `.build/kenlm-round2/`; existing corpus
files and first-round models are not rewritten.

```sh
corpus/.venv/bin/python scripts/kenlm_round2.py all
# To repeat only the common-ARPA control and regenerate the report:
corpus/.venv/bin/python scripts/kenlm_round2.py control
corpus/.venv/bin/python scripts/kenlm_round2.py report
```

Stages can be repeated individually: `train`, `o4a`, `vocabulary`, `evaluate`,
`performance`, `control`, `report`. A repeated completed runtime measurement is
loaded from its JSON file; move the experiment's own performance directory to
an archive before intentionally taking a new pair. This does not touch inputs.

New estimation options, always followed by `-S 40% -T /tmp` and with stdin from
the unchanged `train.txt`:

| Name | Order | Raw count pruning |
| --- | ---: | --- |
| o5c | 5 | 0 0 1 2 3 |
| o4d | 4 | 0 1 2 3 |
| o4e | 4 | 0 0 2 3 |
| o3b | 3 | 0 1 2 |

Each new ARPA is converted with `build_binary -S 40% -T /tmp -q 8 -b 8 trie`.
The optional `-a` option remains omitted, as in round one. Discount failures
retry with `--discount_fallback`, without changing the data, order or pruning.
All eight quantized models are freshly queried on the complete heldout file
using `query -v summary`, and the nonquantized control is queried identically.
Raw ARPA headers are retained for the new models; first-round header counts
were captured before deleting their ARPA intermediates and remain bound to the
unchanged binary hashes.

The first-round o4a ARPA was deleted after successful binary evaluation, so this
round reconstructs it using exactly `-o 4 --prune 0 0 1 2 -S 40% -T /tmp`.
Its order-wise n-gram counts must match the first-round record. The unquantized
control uses `build_binary -S 40% -T /tmp trie` with **neither `-q` nor `-b`**.
An additional requantization control verifies the original quantized binary
against the same reconstructed ARPA; it does not run another estimation job.

Vocabulary statistics read the actual ARPA 1-gram section, then count raw token
occurrences by streaming the original train split. Kneser–Ney probabilities are
not raw occurrence counts. Vocabulary totals include the three model-generated
special tokens; rare-word proportions use the lexical vocabulary excluding
`<s>`, `</s>` and `<unk>`. Suspect-token heuristics and thresholds are recorded
with the results. Valid numbers and long technical terms may be flagged; no
tokens or corpus records are deleted.

Runtime measurements use a separate read-only copy of exactly the first 200,000
heldout lines. For each of o3, o4a, o5 and o4b, the script requests
`/usr/sbin/purge`, runs one fresh `query -v summary` process and immediately runs
another identical process. macOS denied purge with `Operation not permitted`;
therefore the first run is **cache-uncontrolled, not a true cold start**. The
second is OS-cache-warmed, not a persistent in-process model benchmark. No
heavy training/counting work runs during this measurement stage.

The requested real/CPU/RSSMax values are parsed from query's own stderr. On
Darwin, upstream `util/usage.cc::PrintUsage` prints native `ru_maxrss` bytes but
labels them `kB`; reported MiB are converted from the byte values. Raw labels
and independent per-child `wait4` resource values are retained for audit.
Only one first/hot pair is measured per model, so small timing differences are
descriptive rather than statistically established latency improvements.

<!-- KENLM_ROUND2_BEGIN -->
## Second round: existing splits unchanged

All fits use the original train split only. No corpus rewriting, splitting or final combined-data retraining is performed.
Models o5c/o4d/o4e/o3b use -S 40% -T /tmp and -q 8 -b 8 trie; no -a option. o4a ARPA was reconstructed with its original options for the unquantized control and vocabulary inspection.

| Config | MiB | PPL incl. OOV | PPL excl. OOV | n1 | n2 | n3 | n4 | n5 | Query first / hot s | RSS first / hot MiB |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- |
| o3 | 921.16 | 204.923725 | 197.906026 | 3,129,263 | 79,584,106 | 59,463,133 | — | — | 0.6089 / 0.5658 | 895.1 / 895.1 |
| o4a | 1249.88 | 178.021262 | 171.894916 | 3,129,263 | 79,584,106 | 59,463,133 | 26,505,397 | — | 0.6859 / 0.6661 | 1223.8 / 1223.8 |
| o4b | 3074.68 | 164.026023 | 158.310917 | 3,129,263 | 79,584,106 | 278,925,276 | 58,628,863 | — | 0.9683 / 0.9474 | 3048.6 / 3048.6 |
| o5 | 1663.70 | 169.470872 | 163.621169 | 3,129,263 | 79,584,106 | 59,463,133 | 58,628,863 | 17,115,702 | 0.7365 / 0.7521 | 1637.7 / 1637.7 |
| o5c | 1387.17 | 173.814276 | 167.830723 | 3,129,263 | 79,584,106 | 59,463,133 | 26,505,397 | 10,115,504 | not requested | not requested |
| o4d | 604.39 | 196.602005 | 189.976224 | 3,129,263 | 28,199,663 | 31,362,445 | 16,629,825 | — | not requested | not requested |
| o4e | 990.29 | 188.160670 | 181.725351 | 3,129,263 | 79,584,106 | 31,362,445 | 16,629,825 | — | not requested | not requested |
| o3b | 425.27 | 223.471818 | 215.979508 | 3,129,263 | 28,199,663 | 31,362,445 | — | — | not requested | not requested |
| o4a-unquantized | 2101.61 | 177.950797 | 171.821837 | 3,129,263 | 79,584,106 | 59,463,133 | 26,505,397 | — | not requested | not requested |

All complete-heldout evaluations score 16,474,727 tokens including EOS. Runtime columns use only the first 200,000 heldout lines, not the complete-heldout evaluation duration.
Cache purge was denied by macOS (Operation not permitted). First results are cache-uncontrolled, not genuine cold-start measurements; hot results are immediate second fresh-process queries. One pair per model provides descriptive measurements only.
KenLM incorrectly labels native Darwin ru_maxrss values as kB; the table converts the actual byte values to MiB. Original output and independent wait4 metrics are retained.

| Runtime model | First real s | First CPU s | First RSS MiB | Hot real s | Hot CPU s | Hot RSS MiB |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| o3 | 0.608944 | 0.591383 | 895.09 | 0.565803 | 0.569286 | 895.11 |
| o4a | 0.685851 | 0.689066 | 1223.83 | 0.666125 | 0.669628 | 1223.83 |
| o5 | 0.736471 | 0.739880 | 1637.66 | 0.752103 | 0.755836 | 1637.66 |
| o4b | 0.968294 | 0.971624 | 3048.62 | 0.947412 | 0.950876 | 3048.64 |

o4a quantization: including-OOV PPL 178.021262 (8/8 bits) versus 177.950797 (unquantized); size 1249.88 versus 2101.61 MiB.
Quantization reduces size by 40.53%, with an including-OOV PPL increase of 0.070466 (0.0396%).
o4d is smaller and has lower PPL than o3 in this experiment. o4b retains the lowest PPL among the eight quantized configurations, at the largest binary size.

ARPA vocabulary: 3,129,263 including <s>, </s>, <unk>; 3,129,260 lexical tokens. Raw train occurrence counts: exactly once 1,449,559 (46.3227%); at most five 2,186,220 (69.8638%). Fractions exclude the three synthetic special tokens.

Heuristics only; pure decimal digits, signed/decimal/exponent numeric forms, replacement/control/private/unassigned characters or explicit mojibake strings, >32 Unicode scalars or >128 UTF-8 bytes. Valid numbers/names may be flagged. No data is removed.

| Suspect token | Train occurrences | Flags |
| --- | ---: | --- |
| 1 | 1,346,912 | pure_digits |
| 2 | 1,158,701 | pure_digits |
| 3 | 1,073,095 | pure_digits |
| 4 | 901,064 | pure_digits |
| 5 | 807,608 | pure_digits |
| 10 | 797,860 | pure_digits |
| 6 | 716,259 | pure_digits |
| 8 | 687,118 | pure_digits |
| 7 | 676,374 | pure_digits |
| 9 | 674,860 | pure_digits |
| 12 | 654,503 | pure_digits |
| 11 | 588,072 | pure_digits |
| 20 | 337,189 | pure_digits |
| � | 284,867 | garbled_or_nonprinting |
| 15 | 267,796 | pure_digits |
| 30 | 258,135 | pure_digits |
| 16 | 230,162 | pure_digits |
| 18 | 228,425 | pure_digits |
| 2019 | 220,997 | pure_digits |
| 2020 | 218,915 | pure_digits |
| 19 | 215,680 | pure_digits |
| 14 | 211,351 | pure_digits |
| 2010 | 205,943 | pure_digits |
| 21 | 205,090 | pure_digits |
| 17 | 204,838 | pure_digits |
| 25 | 201,379 | pure_digits |
| 13 | 197,677 | pure_digits |
| 2018 | 194,427 | pure_digits |
| 2008 | 191,453 | pure_digits |
| 2016 | 187,375 | pure_digits |

The global top 30 are mostly numbers because they are frequent. Category totals below also expose rare long tokens; categories can overlap.

| Suspect category | Word types | Train occurrences |
| --- | ---: | ---: |
| pure_digits | 519,501 | 28,993,626 |
| numeric_form | 112,431 | 1,229,846 |
| long_token | 11,161 | 11,687 |
| garbled_or_nonprinting | 1,086 | 294,031 |

For example, U+FFFD (replacement character) occurs 284,867 times and 锟斤拷 occurs 378 times. The most frequent long token is `conversaramportelefonenasegunda-feirasobrequestesbilateraiss` (9 occurrences). Full per-category examples are retained in [.build/kenlm-round2/vocabulary/statistics.json](.build/kenlm-round2/vocabulary/statistics.json).

Requantizing the reconstructed ARPA reproduces the original o4a binary: True; including-OOV PPL difference 0. This checks the quantized/unquantized comparison against a common ARPA.

Reproduce without modifying corpus files:
```sh
corpus/.venv/bin/python scripts/kenlm_round2.py all
```
Stages: train, o4a, vocabulary, evaluate, performance, control, report. Source splits are read-only; all new artifacts live under .build/kenlm-round2/. Commands, headers, raw query metrics, cache-purge errors, vocabulary counts and the plot are retained there.

![Second-round size versus perplexity](.build/kenlm-round2/size_vs_ppl.png)

Final combined-data retraining remains unperformed.
<!-- KENLM_ROUND2_END -->

<!-- KENLM_ROUND3_BEGIN -->
## Third round: vocabulary cleaning and pruning

Original train.txt and heldout.txt remain unchanged, with the same split membership and order. All new artifacts live under .build/kenlm-round3/. No final combined-data retraining was performed.

Cleaning contract: [scripts/kenlm_cleaning.py](scripts/kenlm_cleaning.py); portable test vectors: [Tests/KenLMTests/cleaning_vectors.json](Tests/KenLMTests/cleaning_vectors.json).

Rule order: reject a whole line containing U+FFFD, 锟斤拷, 烫烫烫 or 屯屯屯; map numeric tokens to `<num>`; map tokens longer than 32 Unicode scalars to `<oov>`; then apply the version-specific rare-token filter. Numeric grammar: `[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?`, with Unicode decimal digits and ASCII sign/dot/exponent markers. Thus .5, 1. and -1e+3 are numbers; NaN, infinity, grouped 1,000 and Unicode minus are not. No extra normalization, case folding or tokenization is performed. Swift must use unicodeScalars.count, not String.count or UTF-16 length.

clean1 applies only those three base rules. clean2/clean3 additionally replace non-dictionary tokens with surviving base-cleaned train counts strictly below 5/20. Counts and mapping are frozen from train only; unseen heldout words have count zero. Synthetic `<num>`/`<oov>` bypass rare filtering. The ordinary `<oov>` token is distinct from query-reported true vocabulary OOVs. Protected but train-unseen dictionary words remain eligible for true KenLM OOV scoring. The cleaner never emits KenLM-reserved `<unk>`/`<s>`/`</s>`; their appearance in ARPA headers is model-generated.

Dictionary protection uses the exact, case-sensitive text union of Data/Vocabulary/chinese/*.csv and Data/Vocabulary/english/*.csv. Per the existing word-side convention, chinese/phrase/ is excluded. No personal phrases, history or learning archive is read. Source hashes, the protected vocabulary and complete train mapping are pinned under the new output directory.

**PPL is comparable only between pruning/build configurations within the same cleaned version. Different cleaning versions have different vocabularies and evaluation events; do not compare their PPL directly or rank them against the original corpus.**

| Version | Split | Train vocabulary types | Lines kept | Garbled lines deleted | `<num>` replacements | `<num>` share | `<oov>` replacements | `<oov>` share |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| clean1 | train | 2,485,948 | 46,055,391 | 22,471 | 30,199,566 | 3.8096% | 10,792 | 0.0014% |
| clean1 | heldout | 2,485,948 | 888,402 | 598 | 597,848 | 3.8411% | 399 | 0.0026% |
| clean2 | train | 1,400,418 | 46,055,391 | 22,471 | 30,199,566 | 3.8096% | 1,559,322 | 0.1967% |
| clean2 | heldout | 1,400,418 | 888,402 | 598 | 597,848 | 3.8411% | 44,122 | 0.2835% |
| clean3 | train | 1,273,391 | 46,055,391 | 22,471 | 30,199,566 | 3.8096% | 2,673,872 | 0.3373% |
| clean3 | heldout | 1,273,391 | 888,402 | 598 | 597,848 | 3.8411% | 64,047 | 0.4115% |

Vocabulary counts include ordinary `<num>`/`<oov>` markers when observed and exclude the three KenLM-generated special tokens. Replacement shares use tokens in retained lines as denominator; deleted-line tokens are excluded. Token replacements can make previously distinct lines identical, including across splits. Each surviving original line remains in its original split and order; there is no new deduplication or splitting.

Complete-heldout query coverage (including EOS): clean1: 16,452,869 scored tokens, 28,418 true OOV tokens; clean2: 16,452,869 scored tokens, 5,930 true OOV tokens; clean3: 16,452,869 scored tokens, 5,930 true OOV tokens. These expected OOV counts are derived from each frozen train vocabulary and checked against query output.

| Version | Prune | Build -a | MiB | PPL incl. OOV | PPL excl. OOV | n1 | n2 | n3 | n4 | Train `<num>`/`<oov>` share | Heldout `<num>`/`<oov>` share |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- |
| clean1 | 0 1 2 3 | default (omitted) | 564.35 | 161.608418 | 157.432081 | 2,485,951 | 27,062,990 | 30,000,373 | 16,148,801 | 3.8096% / 0.0014% | 3.8411% / 0.0026% |
| clean1 | 0 0 1 2 | default (omitted) | 1173.43 | 147.302146 | 143.430416 | 2,485,951 | 75,185,913 | 56,793,623 | 25,631,566 | 3.8096% / 0.0014% | 3.8411% / 0.0026% |
| clean2 | 0 1 2 3 | default (omitted) | 520.54 | 154.002863 | 153.146048 | 1,400,421 | 26,890,417 | 30,117,518 | 16,251,152 | 3.8096% / 0.1967% | 3.8411% / 0.2835% |
| clean2 | 0 1 2 3 | 22 | 398.88 | 154.002863 | 153.146048 | 1,400,421 | 26,890,417 | 30,117,518 | 16,251,152 | 3.8096% / 0.1967% | 3.8411% / 0.2835% |
| clean2 | 0 0 1 2 | default (omitted) | 1101.94 | 140.631962 | 139.835727 | 1,400,421 | 72,674,771 | 56,880,740 | 25,781,585 | 3.8096% / 0.1967% | 3.8411% / 0.2835% |
| clean3 | 0 1 2 3 | default (omitted) | 514.08 | 151.274424 | 150.433927 | 1,273,394 | 26,530,787 | 30,106,238 | 16,308,159 | 3.8096% / 0.3373% | 3.8411% / 0.4115% |
| clean3 | 0 0 1 2 | default (omitted) | 1087.64 | 138.317066 | 137.535096 | 1,273,394 | 71,400,832 | 56,740,319 | 25,847,836 | 3.8096% / 0.3373% | 3.8411% / 0.4115% |

Within clean1, changing pruning from 0 1 2 3 to 0 0 1 2 reduces including-OOV PPL by 8.85%, while increasing binary size by 107.93%.
Within clean2, changing pruning from 0 1 2 3 to 0 0 1 2 reduces including-OOV PPL by 8.68%, while increasing binary size by 111.69%.
Within clean3, changing pruning from 0 1 2 3 to 0 0 1 2 reduces including-OOV PPL by 8.57%, while increasing binary size by 111.57%.

For clean2 0 1 2 3, -a 22 reduces binary size by 23.37%; including-OOV PPL difference 0, excluding-OOV PPL difference 0.

All six estimates use -o 4 -S 40% -T /tmp and the indicated pruning; all seven binaries use -q 8 -b 8 trie. The extra clean2 0 1 2 3 binary uses -a 22 on exactly the same ARPA as its default-a control, without another estimation. Header counts and exact binary bytes/hashes are retained in each result.json.

### Default loading versus lazy loading

The current query supports -l lazy. On this macOS build, default loading is read (malloc + file read); lazy uses mmap without eager population. Each measurement is one fresh process scoring the complete corresponding heldout, default followed by lazy, without cache clearing. RSSMax is peak resident memory across load and scoring, not virtual address space or an idle/post-load snapshot; a full query can fault in much of a lazy mapping. This does not establish cold-start performance.

| Model | Loading | Real s | CPU s | RSSMax MiB | PPL incl. OOV | PPL excl. OOV | OOV tokens |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| original-o4d | default | 8.671930 | 8.530850 | 578.33 | 196.602005 | 189.976224 | 38,678 |
| original-o4d | lazy | 7.322670 | 7.321640 | 578.31 | 196.602005 | 189.976224 | 38,678 |
| clean2-p0123 | default | 7.254170 | 6.935990 | 509.64 | 154.002863 | 153.146048 | 5,930 |
| clean2-p0123 | lazy | 6.331910 | 6.328350 | 509.62 | 154.002863 | 153.146048 | 5,930 |

These complete-heldout queries show essentially equal peak RSS for default and lazy loading (a difference of about 0.02 MiB per model), with identical PPL and OOV counts. Lazy loading did not materially reduce peak resident memory in this workload. The one-pass timing values are descriptive; default precedes lazy with no cache clearing.

Darwin ru_maxrss is bytes although KenLM prints a literal kB label; MiB are converted from actual byte values and checked against per-child wait4. Raw query output and commands are retained.

Reproduce/resume (completed artifacts are retained):

```sh
corpus/.venv/bin/python scripts/kenlm_round3.py all
```

Stages: prepare, train, loading, report. Data/rules/mappings/statistics: .build/kenlm-round3/data/. Models/headers/query logs: .build/kenlm-round3/models/. Loading measurements: .build/kenlm-round3/loading/. Machine-readable summary: .build/kenlm-round3/summary.json.

Original split hashes, modification times and inodes are verified before and after. No final full-data retraining or native runtime integration is included.

Validation: 14 Python KenLM tests passed; 443 shared Swift tests passed; Debug app build passed. No app installation was performed. Logs are retained under .build/kenlm-round3/validation/.

Artifact audit passed: all train mapping rows, all six cleaned split checksums/counts, seven binary hashes/headers/full-heldout evaluations, the common-ARPA -a 22 control, four loading queries, unchanged original inputs/dictionary/rules/tools and the preexisting README prefix. See .build/kenlm-round3/audit.json.
<!-- KENLM_ROUND3_END -->

<!-- KENLM_FINAL_BEGIN -->
## Final full-data clean2 build

Explicitly authorized final fit. Original train/heldout and every existing train-only model are preserved. Outputs live only in .build/kenlm-final/. The final model is prepared for later app integration; no model is copied into the app by this workflow. final_large.bin is an offline comparison artifact.

### Corpus lineage and full-data mapping

The original train.txt comes from **kenlm-words-v2**, then the existing first-occurrence deduplication and seeded block split in kenlm-selection-v1. It **did not** undergo the old non-Han-boundary splitting / 4–96-character Han-fragment filtering. The split manifest points to upstream input SHA-256 `92660454982b99a22c815871b3345ed664cd04493ae8c2471aa781540f470f47`; the v2 manifest matches the retained snapshot at SHA-256 `608cf0c132dcb7f63dcfbcd012c25c1d35dc4806f5f9a6baf5550216a977052c`. Its scope explicitly says: `Complete pinned local raw archives; no character cap, deduplication or 4–96 Han cutting. Numbers/English/punctuation retained after NFKC; commas/enumeration commas stay within sentences. Original scripts are preserved without simplification. Markup extraction remains heuristic.`.

Code evidence: corpus/prepare_raw_text.py extracts complete raw lines and bypasses the old Han-only cutter; corpus/prepare_kenlm_raw.py uses the shared unigram tokenizer. The v2 tokenizer retains numbers/English/punctuation, uses NFKC and 。！？.!? sentence boundaries and drops >100-token sentences. The existing split already removed exact duplicates; this final run performs no new deduplication or split.

Specifically, the old cutter is corpus/clean/chinese.py::segments(minimum=4, maximum=96), used by the retired fragment-preparation command (now removed). The v2 extraction instead calls corpus/prepare_raw_text.py::extract/raw_documents, which writes raw text lines without invoking segments. Its mC4/LCCC branches bypass the old prepared-text path. Evidence code hashes and per-source tokenizer identities are retained in corpus-provenance.json.

The no-4–96 statement concerns the actual training text rows. Tokenizer dictionary weights reuse the earlier HanLP frequency reference (SHA-256 48f2c4be53b998876efcf9f4149f02d3d6c4d0a14cb15b9ee13ef396c7d48b93); that lexical frequency table is not the earlier cleaned training-text bundle and does not cut these raw-derived text rows.

| Original source | SHA-256 |
| --- | --- |
| train.txt | `db68306a90f17d64f5c09d6b04a3a35fc309f1a37c20386a9b8ce4f1f702796e` |
| heldout.txt | `a01168f4c392acdb41c508cba6ef11c27188e4e87a9997b20d97d8d358d9210f` |

The exact byte concatenation is train first, heldout second (data/full.raw.txt). Counts are recalculated across surviving lines in that entire concatenation before applying clean2. Dictionary protection remains the exact flat Chinese/English CSV text union, excluding chinese/phrase/. No input-method ranking weights are used as occurrence counts. Full raw-token frequencies, outputs and replacement reasons are in data/full-mapping.tsv.

full.clean2.txt: **46,943,793 lines**, **808,294,186 tokens**, **1,407,621 vocabulary types** excluding model-generated special tokens (1,407,624 ARPA unigrams). Deleted garbled lines: **23,069**. `<num>`: 30,797,414 (3.8102%); `<oov>`: 1,582,787 (0.1958%). Shares use retained tokens, without EOS.
Cleaned corpus SHA-256: `22a0a45793fe4824191b63e3e2c6957c6f20fd45f20df39f2ef541c3003539a3`; raw concatenation SHA-256: `5a0e6eec269a88b979d7aebc2a36d433c0d3b10bc4717f3a1d6dc05a9a1e694e`.

The cleaning module remains scripts/kenlm_cleaning.py, contract si-kenlm-cleaning-v1: whole-line rejection of U+FFFD/锟斤拷/烫烫烫/屯屯屯; numeric forms to `<num>`; >32 Unicode scalars to `<oov>`; non-dictionary words with full surviving frequency <5 to `<oov>`. Source tokenization is preserved, with no new normalization, tokenization or sentence cutting.

### Models and train-only comparison

| Artifact | Prune | MiB | n1 | n2 | n3 | n4 | Discount fallback |
| --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
| final.bin | 0 1 2 3 | 405.24 | 1,407,624 | 27,277,539 | 30,674,965 | 16,597,056 | False |
| final_large.bin | 0 0 1 2 | 815.83 | 1,407,624 | 73,620,120 | 57,905,442 | 26,325,744 | False |

Both binaries use -a 22 -q 8 -b 8 trie. The small model is compared against the identically packed train-only clean2 p0123-a22 model. For the large model, n-gram counts use train-only clean2 p0012; its earlier binary omitted -a, so its binary-size difference is not a like-for-like corpus-growth measurement.

| Model | Order | Train-only count | Full count | Difference | Change |
| --- | ---: | ---: | ---: | ---: | ---: |
| final | 1 | 1,400,421 | 1,407,624 | +7,203 | +0.514% |
| final | 2 | 26,890,417 | 27,277,539 | +387,122 | +1.440% |
| final | 3 | 30,117,518 | 30,674,965 | +557,447 | +1.851% |
| final | 4 | 16,251,152 | 16,597,056 | +345,904 | +2.128% |
| final_large | 1 | 1,400,421 | 1,407,624 | +7,203 | +0.514% |
| final_large | 2 | 72,674,771 | 73,620,120 | +945,349 | +1.301% |
| final_large | 3 | 56,880,740 | 57,905,442 | +1,024,702 | +1.801% |
| final_large | 4 | 25,781,585 | 26,325,744 | +544,159 | +2.111% |

Matched-packing size: 398.88 → 405.24 MiB (+1.594%).


Growth near 2% is a reasonableness expectation, not a forced threshold: vocabulary remapping and pruning-frequency crossings can change different orders by different proportions.

### Functional scoring and loading checks

There is **no final heldout PPL evaluation**: former heldout lines now participate in training. The 20 natural sentences were authored before scoring, and their 20 bad controls reverse the same cleaned body tokens while preserving final punctuation. Token multisets, lengths and OOV counts are equal within each pair. The fixed criterion is 20/20 natural-sentence wins and median log10-probability margin ≥0.25 per scored token including EOS. This is a synthetic sanity check, not a product-quality benchmark.

| Model/loading | Good wins | Median log10 margin/token | Passed | RSSMax MiB |
| --- | ---: | ---: | --- | ---: |
| final-default | 20/20 | 1.001415 | True | 393.31 |
| final-lazy | 20/20 | 1.001415 | True | 17.62 |
| final_large-default | 20/20 | 1.121843 | True | 803.89 |

Both models contain ordinary nonzero-vocabulary-ID `<num>` and `<oov>` tokens, checked in ARPA and query -v word. final.bin loads with -l lazy and produces exactly the same pair scores as default loading. RSSMax uses native Darwin bytes converted to MiB. The complete 40 sentences, tokenization, raw scores and per-pair margins are retained in sanity/pairs.json and sanity/results.json.

| Pair | Natural sentence | Bad token order | Good log10 | Bad log10 | Margin/token |
| --- | --- | --- | ---: | ---: | ---: |
| 1 | 今天早上我坐地铁去公司上班。 | 上班 公司 坐地铁去 我 早上 今天 。 | -19.160875 | -28.351614 | 1.148842 |
| 2 | 下班以后我们一起去餐厅吃晚饭。 | 晚饭 餐厅吃 去 一起 我们 以后 下班 。 | -23.422716 | -31.628284 | 0.911730 |
| 3 | 请你帮我把窗户关上。 | 关上 窗户 你帮我把 请 。 | -20.711401 | -24.921082 | 0.701614 |
| 4 | 老师正在教室里给学生讲课。 | 讲课 学生 给 教室里 正在 老师 。 | -24.560575 | -30.693510 | 0.766617 |
| 5 | 妈妈每天都会给孩子准备早餐。 | 准备早餐 孩子 都会给 每天 妈妈 。 | -21.960989 | -29.368060 | 1.058153 |
| 6 | 这本书的内容非常有趣，我想再读一遍。 | 再读一遍 想 我 , 非常有趣 本书的内容 这 。 | -25.290280 | -35.251670 | 1.106821 |
| 7 | 如果明天下雨，我们就取消这次活动。 | 活动 这次 取消 就 我们 , 下雨 明天 如果 。 | -24.559978 | -36.849224 | 1.117204 |
| 8 | 我已经把需要修改的文件发给你了。 | 发给你了 文件 的 修改 需要 把 已经 我 。 | -24.391365 | -30.295660 | 0.590430 |
| 9 | 大家正在会议室里讨论新的工作计划。 | 计划 工作 的 新 讨论 会议室里 正在 大家 。 | -29.156204 | -34.963990 | 0.580779 |
| 10 | 他认真检查了程序中的错误，然后重新运行测试。 | 测试 运行 重新 然后 , 错误 的 中 程序 了 认真检查 他 。 | -30.952904 | -49.741520 | 1.342044 |
| 11 | 为了保护环境，我们应该减少一次性塑料的使用。 | 使用 的 塑料 一次性 减少 应该 我们 , 环境 保护 为了 。 | -26.792833 | -43.843563 | 1.311595 |
| 12 | 医生建议他每天坚持锻炼并且早点休息。 | 早点休息 并且 坚持锻炼 每天 他 医生建议 。 | -26.238632 | -33.778740 | 0.942514 |
| 13 | 春天来了，公园里的花慢慢开了。 | 了 慢慢开 公园里的花 , 春天来了 。 | -23.829110 | -28.054150 | 0.603577 |
| 14 | 我们到达车站的时候，火车已经开走了。 | 开走了 已经 火车 , 时候 的 车站 到达 我们 。 | -28.285833 | -38.677284 | 0.944677 |
| 15 | 我想知道这个问题应该怎么解决。 | 解决 怎么 应该 问题 这个 知道 想 我 。 | -15.855074 | -31.789250 | 1.593418 |
| 16 | 请在收到消息以后尽快回复。 | 尽快回复 以后 收到消息 在 请 。 | -25.305569 | -28.828400 | 0.503262 |
| 17 | 他把钥匙放在桌子上，然后出门去买东西。 | 去买东西 出门 然后 , 在桌子上 放 把钥匙 他 。 | -29.078825 | -34.923687 | 0.584486 |
| 18 | 经过大家的共同努力，这个项目终于完成了。 | 了 完成 终于 项目 这个 , 共同努力 的 大家 经过 。 | -25.881302 | -42.160350 | 1.356587 |
| 19 | 这家餐厅的饭菜很好吃，服务也很周到。 | 很周到 也 服务 , 菜很好吃 饭 的 家餐厅 这 。 | -31.288235 | -46.100105 | 1.346534 |
| 20 | 我希望以后能够有更多时间陪伴家人。 | 家人 陪伴 更多时间 有 能够 以后 希望 我 。 | -18.032969 | -33.656258 | 1.562329 |

### Commands, metadata and reproducibility

```sh
corpus/.venv/bin/python scripts/kenlm_final.py all
```

The completed run also used the independently resumable acceptance/report stages, reusing the already built model bytes:

```sh
corpus/.venv/bin/python scripts/kenlm_final.py sanity
corpus/.venv/bin/python scripts/kenlm_final.py report
```

The original sources are copied and counted in order by the prepare stage, then cleaned with the recalculated full mapping. Every external command is captured with exact argv, stdin/stdout/stderr paths, status and elapsed time in commands.jsonl. Executed training/build/query commands:

```sh
/Users/eric/src/si/corpus/.cache/kenlm-build/bin/lmplz -o 4 --prune 0 1 2 3 -S 40% -T /tmp < /Users/eric/src/si/.build/kenlm-final/full.clean2.txt > /Users/eric/src/si/.build/kenlm-final/final.arpa 2> /Users/eric/src/si/.build/kenlm-final/final.lmplz.log
/Users/eric/src/si/corpus/.cache/kenlm-build/bin/build_binary -a 22 -q 8 -b 8 trie /Users/eric/src/si/.build/kenlm-final/final.arpa /Users/eric/src/si/.build/kenlm-final/final.bin < /dev/null > /Users/eric/src/si/.build/kenlm-final/final.build.stdout 2> /Users/eric/src/si/.build/kenlm-final/final.build.log
/Users/eric/src/si/corpus/.cache/kenlm-build/bin/lmplz -o 4 --prune 0 0 1 2 -S 40% -T /tmp < /Users/eric/src/si/.build/kenlm-final/full.clean2.txt > /Users/eric/src/si/.build/kenlm-final/final_large.arpa 2> /Users/eric/src/si/.build/kenlm-final/final_large.lmplz.log
/Users/eric/src/si/corpus/.cache/kenlm-build/bin/build_binary -a 22 -q 8 -b 8 trie /Users/eric/src/si/.build/kenlm-final/final_large.arpa /Users/eric/src/si/.build/kenlm-final/final_large.bin < /dev/null > /Users/eric/src/si/.build/kenlm-final/final_large.build.stdout 2> /Users/eric/src/si/.build/kenlm-final/final_large.build.log
/Users/eric/src/si/corpus/.cache/kenlm-build/bin/query -v sentence -v summary /Users/eric/src/si/.build/kenlm-final/final.bin < /Users/eric/src/si/.build/kenlm-final/sanity/pairs.txt > /Users/eric/src/si/.build/kenlm-final/sanity/final-default.stdout 2> /Users/eric/src/si/.build/kenlm-final/sanity/final-default.stderr
/Users/eric/src/si/corpus/.cache/kenlm-build/bin/query -v sentence -v summary -l lazy /Users/eric/src/si/.build/kenlm-final/final.bin < /Users/eric/src/si/.build/kenlm-final/sanity/pairs.txt > /Users/eric/src/si/.build/kenlm-final/sanity/final-lazy.stdout 2> /Users/eric/src/si/.build/kenlm-final/sanity/final-lazy.stderr
/Users/eric/src/si/corpus/.cache/kenlm-build/bin/query -v word /Users/eric/src/si/.build/kenlm-final/final.bin < /Users/eric/src/si/.build/kenlm-final/sanity/markers.txt > /Users/eric/src/si/.build/kenlm-final/sanity/final-markers.stdout 2> /Users/eric/src/si/.build/kenlm-final/sanity/final-markers.stderr
/Users/eric/src/si/corpus/.cache/kenlm-build/bin/query -v sentence -v summary /Users/eric/src/si/.build/kenlm-final/final_large.bin < /Users/eric/src/si/.build/kenlm-final/sanity/pairs.txt > /Users/eric/src/si/.build/kenlm-final/sanity/final_large-default.stdout 2> /Users/eric/src/si/.build/kenlm-final/sanity/final_large-default.stderr
/Users/eric/src/si/corpus/.cache/kenlm-build/bin/query -v word /Users/eric/src/si/.build/kenlm-final/final_large.bin < /Users/eric/src/si/.build/kenlm-final/sanity/markers.txt > /Users/eric/src/si/.build/kenlm-final/sanity/final_large-markers.stdout 2> /Users/eric/src/si/.build/kenlm-final/sanity/final_large-markers.stderr
```

KenLM source: https://kheafield.com/code/kenlm.tar.gz, archive SHA-256 `6bb66b6c17f6d23907bd6258ee585328b3e5f5f2b201d41c5f6bd0c390c2c913`. The original metadata recorded `git_commit` as null. Inspection of the same verified archive during native integration found `GIT_REVISION` at `b32c19389737a5def8bbc4623de809ced3091187`. The original metadata is preserved. Binary format version is 5, and all three executable hashes are retained.

final.bin SHA-256: `b8ff26637fa93e5d9a2bc4aacd9e22e00b4d30d421ce1d158f7e6cb8889ca286`. final_large.bin SHA-256: `12f6d1beeac14828a71cc048b48f093b98e44d68274cc4b655042b6f3beec60d`.
final.meta.json contains model/ARPA hashes and timestamps, KenLM source/executable identity, rule version/module hash/Unicode version, cleaning_vectors.json SHA-256, dictionary source and protected-vocabulary hashes, full mapping/corpus hashes, counts and exact commands. Compatibility fingerprint: `82ab31b58d309e6ae7da3ac9318e16bf73bc980b7c42b6406070f1e9cad7c9a5`. The separate development installer and loader consume this metadata as described below.

git check-ignore confirms .gitignore .build/ covers final.bin, final_large.bin and both ARPAs. None is staged or committed. Original source hashes/mtime/inodes and every existing train-only model are checked before and after. Build/scoring artifacts stay local.

Validation: 19 Python KenLM tests, 443 shared Swift tests and the Debug app build passed. Validation commands: `corpus/.venv/bin/python -m unittest discover -s Tests/KenLMTests -v`; `./scripts/test.sh --disable-sandbox`; `./scripts/build.sh`.

Artifact audit passed; see .build/kenlm-final/audit.json for mapping, corpus, model, metadata and preservation checks.
<!-- KENLM_FINAL_END -->

## Development KenLM ranking

### Historical development configuration

The later [production preset](#production-kenlm-ranking) replaces these switches.
During this experiment, the Debug Settings switches **Use KenLM for Chinese candidates** and
**Rank full coverage first** are independent and default off. Coverage puts
whole results before prefixes and longer prefix spans before shorter spans.
Within a span the engine compares scores. Pins, remembered choices, the
shortlist, exact consumed source boundaries and literal fallback retain their
existing contracts. Both switches are disabled under secure event input.

```sh
corpus/.venv/bin/python scripts/install_kenlm_model.py
```

The installer verifies the metadata and computes SHA-256 while copying the
full-data binary into a new versioned directory in
`~/Library/Application Support/SI/KenLM/`. It atomically selects that directory
through `current.json`, which records the checksum, bytes and nanosecond
modification times of the installed model and metadata. The Debug loader reads
the two small manifests, checks file stamps and opens a lazy memory mapping on
a worker. A missing or incompatible installation leaves dictionary ranking
available. Installation neither enables the switches nor registers the app.
The Release build uses the legacy ranking.

The reranker uses the actual winning dictionary path for each candidate ID.
It adds the weighted KenLM log probability in bits and replaces the existing
Chinese per-word insertion cost. Frequency stays at weight 1 in the selected
profiles. It starts at BOS, resets on a language boundary and scores only the
emitted lexical words, without EOS or an inferred suffix. The app uses no host
context. Offline context probes explicitly supply up to three preceding
tokens from the same clause. English LM weight stays at zero. Tokens that
clean to `<oov>` or lack a model index are scored through the ordinary
`<oov>` vocabulary entry. The `lm_oov_ratio` feature is the share among
scored candidate tokens. Active LM ranking suspends automatic prefix
confirmation because the existing confidence check uses legacy scores.

The coverage experiment preserves existing English scores within each
coverage group. The difficulty set keeps the intended outputs for
`goon` and `cannot` so the benchmark reports any ranking mismatches.

### Evaluation protocol

All ranking measurements use the train-only model identified above. Both
benchmark executables reject the full-data binary by hash. The original
heldout file and compiled dictionaries are hashed in
`.build/kenlm-ranking/dataset/manifest.json`; original train and heldout files
are unchanged.

The preparation script splits tokenized lines at Unicode punctuation and
chooses one eligible Han-only clause uniformly within each eligible line. It
then samples 20,000 clauses from different source lines with seed 20261106.
Words use their highest-weight dictionary reading, breaking ties by
spelling, with character readings as a fallback. No clause is filtered by
candidate-pool reachability. Whole clauses with identical gold text or
whole-clause Pinyin stay on the same side of the split. The development set
has 11,997 clauses and 45,676 queries. The frozen test has 8,003 clauses and
30,544 queries. Each source clause contributes a whole-clause query, a random
one- to four-word span, and, where possible, a separate noninitial span with
and without its actual preceding tokens. Common short spans can repeat across
splits. The 30,841-line strict subset uses the previous whole-line,
minimum-four-word and unique-reading rules. Its diagnostic scores can overlap
development clauses.

English evaluation uses both providers and 100 ordinary dictionary words from
each of five frequency bands. Each word has a whole spelling and a random
proper prefix at least three letters long. Eligible whole keys have at least
four ASCII letters and match dictionary text case-insensitively. The LM
factorial uses the same Chinese weight and insertion cost on both sides of
the coverage toggle to isolate coverage. A separate row profile uses the
Debug combined preset's selected insertion cost. English LM is zero in
every profile.

The engine builds one candidate pool per query. Recall is the fraction with
an exact nonliteral whole match in that pool. Top-1 and Top-5 use the
shortlist with exact output bytes and count unreachable examples in the
denominator. Edit error is the summed Levenshtein distance of the first result
divided by gold character count. Benchmarks use a Release CLI with warmed
dictionary initialization. Per-query latency includes candidate generation,
experimental scoring, ordering and shortlisting. It excludes process
startup, model checksum verification, host rendering and interprocess input.

```sh
si_run=.build/kenlm-ranking
si_model=.build/kenlm-round3/models/clean2/p0123-a22/model.trie
corpus/.venv/bin/python scripts/prepare_kenlm_ranking.py "$si_run/dataset"
swift build -c release -debug-info-format none --scratch-path "$si_run/build" --disable-sandbox
si_products=$(swift build -c release --scratch-path "$si_run/build" --show-bin-path)
"$si_products/SIBenchmark" --kenlm tune "$si_model" "$si_run/dataset" > "$si_run/tuning.json"
for si_mode in test strict english; do
    "$si_products/SIBenchmark" --kenlm "$si_mode" "$si_model" "$si_run/dataset" "$si_run/tuning.json" > "$si_run/$si_mode.json"
done
"$si_products/SIBenchmark" --kenlm hard "$si_model" "$si_run/dataset" eval/ranking/hard-cases.tsv "$si_run/tuning.json" > "$si_run/hard.json"
printf '%s\n' '{"id":"example","input":"nihaopengyou"}' |
    "$si_products/SICandidateExport" --features "$si_model" > "$si_run/features-smoke.csv"
```

The feature export uses the same pool as the app. It writes absolute and
within-span features, including coverage, token counts and lengths, dictionary
frequency, LM score and OOV ratio. The export reads explicit input rows and
does not collect compositions from the running app.

### Corpus filter audit

The source has 889,000 lines and 2,351,011 punctuation-delimited clauses. Of these clauses, 612,582 contain non-Han tokens and 125 Han clauses lack usable readings. The fallback was available but unused in the retained Han clauses.

| First exclusion reason | Lines | Share of source | Punctuation | Digits | English | Polyphonic single-character token |
| --- | --- | --- | --- | --- | --- | --- |
| No Han-only clause | 121,808 | 13.7017% | 77.93% | 64.72% | 49.85% | 40.66% |
| No readable Han clause | 33 | 0.0037% | 87.88% | 30.30% | 39.39% | 54.55% |
| Strict: fewer than four words | 50,975 | 5.7340% | 0.00% | 0.00% | 0.00% | 22.12% |
| Strict: whole line contains non-Han material | 737,971 | 83.0114% | 96.36% | 34.31% | 18.73% | 68.49% |
| Strict: missing or nonunique word reading | 69,213 | 7.7855% | 0.00% | 0.00% | 0.00% | 97.03% |

Feature shares are within excluded lines and can overlap. Clause sampling limits one
query family per source line. The unsampled eligible lines are not filtered errors.

### Development weight selection

The 101 configurations cover the legacy path, coverage alone, 11 insertion-only
settings, and the cross product of four LM weights, 11 insertion penalties and
two coverage settings. The Chinese LM weights are 0.25, 0.5, 1 and 2. The
insertion penalties are −4, 0, 2, 4, 6, 8, 10, 12, 16, 22 and 28.85 bits.
Selection maximizes pooled development Top-1, then prefers smaller LM weight
and the insertion penalty closest to the legacy value. Only the selected
profiles run on the frozen test.

| Profile | LM weight | Insertion bits | Coverage | Development Top-1 |
| --- | --- | --- | --- | --- |
| Legacy | 0 | 28.854 | Off | 42.34% |
| Coverage only | 0 | 28.854 | On | 44.35% |
| Insertion only | 0 | 28.85 | Off | 42.35% |
| LM | 0.25 | 22 | Off | 43.11% |
| LM + coverage | 0.25 | 28.85 | On | 45.96% |

### Frozen Chinese test

Each accuracy cell is **Top-1 / Top-5**. Length is in gold Han characters.

| Track / length | Queries | Pool recall | Legacy | Coverage only | Insertion only | LM | LM + coverage |
| --- | --- | --- | --- | --- | --- | --- | --- |
| All queries | 30,544 | 64.94% | 41.69% / 56.92% | 43.94% / 57.82% | 41.69% / 56.92% | 43.06% / 58.97% | 45.56% / 59.48% |
| Whole clause | 8,003 | 47.06% | 30.33% / 43.33% | 33.44% / 44.61% | 30.33% / 43.35% | 31.06% / 44.70% | 34.40% / 45.57% |
| Whole clause, 1–8 | 4,772 | 55.53% | 37.51% / 51.47% | 40.88% / 53.00% | 37.51% / 51.47% | 37.91% / 52.89% | 41.91% / 53.81% |
| Whole clause, 9–16 | 2,426 | 42.17% | 24.28% / 38.25% | 27.82% / 39.37% | 24.28% / 38.29% | 25.47% / 39.82% | 28.65% / 40.85% |
| Whole clause, 17–32 | 766 | 12.14% | 6.27% / 10.97% | 6.53% / 11.23% | 6.27% / 10.97% | 7.70% / 11.36% | 7.57% / 11.49% |
| Whole clause, 33+ | 39 | 0.00% | 0.00% / 0.00% | 0.00% / 0.00% | 0.00% / 0.00% | 0.00% / 0.00% | 0.00% / 0.00% |
| Random short span | 8,003 | 71.15% | 47.58% / 62.86% | 49.24% / 63.64% | 47.58% / 62.86% | 47.81% / 64.25% | 50.38% / 64.75% |
| Random short span, 1–8 | 7,799 | 70.74% | 47.22% / 62.34% | 48.87% / 63.10% | 47.22% / 62.34% | 47.48% / 63.73% | 49.88% / 64.19% |
| Random short span, 9–16 | 203 | 86.70% | 61.58% / 82.76% | 64.04% / 84.24% | 61.58% / 82.76% | 60.10% / 84.24% | 69.46% / 86.21% |
| Random short span, 17–32 | 1 | 100.00% | 0.00% / 100.00% | 0.00% / 100.00% | 0.00% / 100.00% | 100.00% / 100.00% | 100.00% / 100.00% |
| Matched span without context | 7,269 | 71.36% | 44.70% / 61.12% | 46.80% / 61.89% | 44.70% / 61.12% | 45.70% / 62.46% | 47.56% / 62.79% |
| Matched span without context, 1–8 | 7,117 | 71.04% | 44.30% / 60.64% | 46.41% / 61.42% | 44.30% / 60.64% | 45.27% / 61.99% | 47.07% / 62.29% |
| Matched span without context, 9–16 | 150 | 86.00% | 63.33% / 83.33% | 65.33% / 84.00% | 63.33% / 83.33% | 65.33% / 84.00% | 70.00% / 86.00% |
| Matched span without context, 17–32 | 2 | 100.00% | 50.00% / 100.00% | 50.00% / 100.00% | 50.00% / 100.00% | 100.00% / 100.00% | 100.00% / 100.00% |
| Matched span with context | 7,269 | 71.36% | 44.70% / 61.12% | 46.80% / 61.89% | 44.70% / 61.12% | 48.40% / 65.37% | 50.56% / 65.70% |
| Matched span with context, 1–8 | 7,117 | 71.04% | 44.30% / 60.64% | 46.41% / 61.42% | 44.30% / 60.64% | 48.03% / 64.99% | 50.13% / 65.28% |
| Matched span with context, 9–16 | 150 | 86.00% | 63.33% / 83.33% | 65.33% / 84.00% | 63.33% / 83.33% | 65.33% / 83.33% | 70.00% / 85.33% |
| Matched span with context, 17–32 | 2 | 100.00% | 50.00% / 100.00% | 50.00% / 100.00% | 50.00% / 100.00% | 100.00% / 100.00% | 100.00% / 100.00% |

The strict diagnostic reuses the same selected weights. It shares 486 source
lines with development and 325 with frozen test.

| Track / length | Queries | Pool recall | Legacy | Coverage only | Insertion only | LM | LM + coverage |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Strict subset | 30,841 | 63.85% | 37.41% / 58.04% | 44.99% / 60.44% | 37.41% / 58.04% | 38.61% / 60.23% | 45.17% / 62.04% |

On frozen whole clauses, coverage alone adds 3.11 percentage points of Top-1,
LM alone adds 0.73 and both add 4.07. Candidate-pool recall falls from 55.53%
at 1–8 characters to 12.14% at 17–32. All 39 clauses with at least 33 characters
are unreachable in the existing pool. Explicit preceding tokens raise
combined Top-1 from 47.56% to 50.56% on the same 7,269 noninitial spans.
That context is available only in the offline diagnostic.

**Latency in ms, P50 / P95.** The model uses lazy mapping. The run did not clear the OS page cache.

| Track / length | Legacy | Coverage only | Insertion only | LM | LM + coverage |
| --- | --- | --- | --- | --- | --- |
| Frozen all | 3.69 / 17.55 | 3.78 / 17.67 | 3.77 / 17.65 | 4.21 / 18.30 | 4.21 / 18.29 |
| Frozen whole clauses | 8.02 / 26.72 | 8.11 / 26.85 | 8.10 / 26.84 | 8.56 / 27.58 | 8.56 / 27.57 |
| Whole clauses, 1–8 | 5.27 / 11.38 | 5.37 / 11.54 | 5.35 / 11.52 | 5.79 / 12.43 | 5.79 / 12.43 |
| Whole clauses, 9–16 | 15.98 / 25.52 | 16.06 / 25.72 | 16.05 / 25.71 | 16.48 / 26.58 | 16.48 / 26.58 |
| Whole clauses, 17–32 | 24.81 / 39.88 | 24.88 / 40.03 | 24.87 / 40.02 | 25.22 / 41.79 | 25.23 / 41.79 |
| Whole clauses, 33+ | 0.02 / 0.03 | 0.02 / 0.03 | 0.02 / 0.03 | 0.02 / 0.03 | 0.02 / 0.03 |
| Strict subset | 9.98 / 21.63 | 10.06 / 21.73 | 10.05 / 21.72 | 10.42 / 22.25 | 10.42 / 22.25 |

| Track | Legacy | Coverage only | Insertion only | LM | LM + coverage |
| --- | --- | --- | --- | --- | --- |
| Frozen all edit error | 45.23% | 44.45% | 45.23% | 44.28% | 43.48% |
| Frozen whole edit error | 64.47% | 63.81% | 64.47% | 63.79% | 63.02% |
| Strict edit error | 31.83% | 30.30% | 31.83% | 31.27% | 30.02% |

### English regression

Each accuracy cell is **Top-1 / Top-5**. Weight bands use the compiled dictionary weights.

| Track / weight | Queries | Pool recall | Legacy | Coverage only | Chinese LM | Chinese LM + coverage | Debug combined preset |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Whole | 500 | 100.00% | 92.60% / 98.60% | 97.00% / 99.60% | 87.60% / 97.80% | 95.60% / 99.20% | 99.00% / 99.80% |
| Whole, 0–9 | 100 | 100.00% | 84.00% / 96.00% | 94.00% / 99.00% | 75.00% / 94.00% | 92.00% / 99.00% | 97.00% / 99.00% |
| Whole, 10–99 | 100 | 100.00% | 89.00% / 97.00% | 94.00% / 99.00% | 86.00% / 96.00% | 94.00% / 97.00% | 99.00% / 100.00% |
| Whole, 100–999 | 100 | 100.00% | 94.00% / 100.00% | 99.00% / 100.00% | 89.00% / 99.00% | 97.00% / 100.00% | 99.00% / 100.00% |
| Whole, 1000–9999 | 100 | 100.00% | 98.00% / 100.00% | 99.00% / 100.00% | 93.00% / 100.00% | 98.00% / 100.00% | 100.00% / 100.00% |
| Whole, 10000+ | 100 | 100.00% | 98.00% / 100.00% | 99.00% / 100.00% | 95.00% / 100.00% | 97.00% / 100.00% | 100.00% / 100.00% |
| Prefix | 500 | 100.00% | 19.80% / 54.20% | 33.00% / 67.40% | 15.60% / 48.00% | 30.80% / 63.80% | 35.20% / 73.40% |
| Prefix, 0–9 | 100 | 100.00% | 10.00% / 39.00% | 27.00% / 60.00% | 8.00% / 33.00% | 23.00% / 58.00% | 28.00% / 66.00% |
| Prefix, 10–99 | 100 | 100.00% | 19.00% / 39.00% | 27.00% / 52.00% | 15.00% / 35.00% | 25.00% / 52.00% | 28.00% / 55.00% |
| Prefix, 100–999 | 100 | 100.00% | 18.00% / 54.00% | 29.00% / 68.00% | 18.00% / 49.00% | 28.00% / 62.00% | 30.00% / 72.00% |
| Prefix, 1000–9999 | 100 | 100.00% | 19.00% / 61.00% | 28.00% / 69.00% | 13.00% / 54.00% | 27.00% / 65.00% | 33.00% / 81.00% |
| Prefix, 10000+ | 100 | 100.00% | 33.00% / 78.00% | 54.00% / 88.00% | 24.00% / 69.00% | 51.00% / 82.00% | 57.00% / 93.00% |

| English latency, ms P50 / P95 | Legacy | Coverage only | Chinese LM | Chinese LM + coverage | Debug combined preset |
| --- | --- | --- | --- | --- | --- |
| Whole | 2.75 / 10.67 | 2.89 / 10.82 | 2.98 / 11.02 | 3.05 / 11.05 | 3.05 / 11.06 |
| Prefix | 1.46 / 5.80 | 1.54 / 5.88 | 1.60 / 6.08 | 1.63 / 6.15 | 1.64 / 6.15 |

With coverage off, Chinese reranking lowers English Top-1 by 5.00 percentage
points on whole words and 4.20 points on prefixes in bilingual mode, even at
zero English LM weight. The Debug combined preset uses 28.85 insertion bits.
The factorial uses 22 bits to hold the penalty fixed across its LM profiles.

### Authored hard cases

The coverage experiment preserves the original English scores. Both target
outputs remain selectable and commit the full input. The benchmark records
four of six Top-1 passes with coverage alone and with the Debug combined
preset. The Swift suite checks English score parity and exact target commit bytes.

| Input | Expected | English only, coverage | Bilingual, coverage | Bilingual, LM + coverage | Top-1 result |
| --- | --- | --- | --- | --- | --- |
| `goon` | `go on` | `goon` | `goon` | `goon` | Fail |
| `into` | `into` | `into` | `into` | `into` | Pass |
| `also` | `also` | `also` | `also` | `also` | Pass |
| `maybe` | `maybe` | `maybe` | `maybe` | `maybe` | Pass |
| `cannot` | `cannot` | `can not` | `can not` | `can not` | Fail |
| `myself` | `myself` | `myself` | `myself` | `myself` | Pass |

### Validation and limits

| Stage | Swift tests passed | Debug build |
| --- | --- | --- |
| a. Native loader and cleaning | 446 | Passed |
| b. LM scoring and zero-weight parity | 448 | Passed |
| c. Independent coverage strategy | 449 | Passed |
| d. Shared pool and feature export | 451 | Passed |
| e. Dataset and benchmark | 452 | Passed |
| f. English guard cases and final configuration | 453 | Passed |

An independent Release probe compared Git baseline `8d1d25a` with the current
code using the installed model and both LM weights at zero. Across 36 authored
inputs and four language configurations, all 144 snapshots matched byte for
byte, including preview and full candidate IDs, score bit patterns, window
ordering, every visible selection’s committed bytes, remainder and cursor.
The comparison covered 10,487 full-pool candidates and 6,593 window selections.

The final Swift pass used the installed model and compared native token scores
with KenLM query. The 19 Python KenLM tests also passed. Dataset and split
hashes, native model stamps, CSV grouping, Xcode project and localization
syntax, and Git ignore rules were verified. The Debug bundle contains no
KenLM binary or ARPA assets. The original corpus and train-only model were
read-only inputs. Live input-method and VoiceOver checks remain pending.

## Ranking diagnostics and English insertion cost

This round uses the existing frozen development, test, strict and English query
files. The original heldout text supplies gold token boundaries for the
diagnostic only. Dictionary and model files are read-only inputs. The Chinese
grid uses the same train-only model and selection rule as the preceding round.
The full-data model is used only by the existing loader smoke tests.

### Recall attribution

The probe checks the ordinary Chinese candidate pool for exact, nonliteral,
whole-clause output. For a miss, it first records a hard input or output
restriction, if present. Otherwise it runs a gold-prefix dynamic program over
the decoder's actual syllable cuts and dictionary spans, with the ordinary
per-span row cap of 32 and then with only that row cap removed. A path in the
first probe indicates a beam or terminal candidate-limit loss. A path appearing
only in the second probe indicates a lexical row-cap loss. Both count as
search pruning.

If neither probe finds a path, an exact dictionary-only counterfactual matches
the frozen spelling and gold text without the decoder's cut and span limits.
A successful path indicates a decoder restriction. With no path, an absent
original gold token takes precedence as a dictionary gap. Remaining cases
count as reading incompatibilities. The original gold token membership and
multiple dictionary readings are also counted independently. These data
contain dictionary-generated Pinyin and no independent pronunciation labels,
so the diagnosis cannot judge whether the chosen reading is natural in context.

### English word audit and grid

The audit treats alphabetic ASCII typing keys whose output lowercases to the
same key as word forms. For case variants it keeps the highest dictionary
weight, with a deterministic text tie-break. It enumerates all nonempty
two-word splits, including one-letter parts present in the dictionary.
The reported ratios are the whole word's weight divided by each part's
weight, and divided by their product. The last ratio uses a floor of one,
matching the frequency term in the engine. The smallest product ratios form
the 200-item review list. Upstream weights are ranking inputs; these ratios
are descriptive and do not by themselves predict the first candidate.

The generated guards use lowercase, alphabetic whole words at least four
letters long with dictionary weight strictly greater than 1,000. A SHA-256
word-key split assigns approximately 60% to development and keeps every
form's whole and prefix queries in the same group across both sources. The
original 1,000-query English benchmark is also reported in full for comparison.
The new English grid tunes on the development portion of the original whole,
original prefix and generated guard tracks with equal weight per track.
It maximizes the mean Top-1 and breaks exact ties by distance to the legacy
cost. Candidate generation and coverage stay fixed in bilingual mode during
this selection. Both LM weights are zero during the English grid. The
held-back groups use only the legacy and selected English penalties.

`w_wip_en` is an absolute insertion cost in bits. Its default is
`23 / ln(2)`. The reranker adds the difference between the legacy and chosen
cost once per English dictionary token, including the English part of mixed
paths. It uses the existing emitted candidate pool and winning derivation, so
the experiment leaves beam membership intact. No case-specific weights are
used. The selected value was evaluated offline before adoption in the
[production preset](#production-kenlm-ranking).

### Reproduction

```sh
si_run=.build/kenlm-ranking-diagnostics
si_dataset=.build/kenlm-ranking/dataset
si_model=.build/kenlm-round3/models/clean2/p0123-a22/model.trie
swift build -c release -debug-info-format none --scratch-path "$si_run/build" --disable-sandbox --product SIBenchmark
si_cli="$(swift build -c release --scratch-path "$si_run/build" --show-bin-path)/SIBenchmark"

"$si_cli" --kenlm recall "$si_model" "$si_dataset" > "$si_run/recall-probe.json"
corpus/.venv/bin/python scripts/diagnose_kenlm_ranking.py recall "$si_dataset" "$si_run/recall-probe.json" "$si_run"
corpus/.venv/bin/python scripts/diagnose_kenlm_ranking.py english "$si_dataset" "$si_run"
"$si_cli" --english-ranking audit "$si_run/english-audit.jsonl" > "$si_run/english-audit.json"
corpus/.venv/bin/python scripts/diagnose_kenlm_ranking.py summarize-english "$si_run"
"$si_cli" --english-ranking grid "$si_dataset/english.jsonl" "$si_run/english-guards.jsonl" > "$si_run/english-grid.json"

"$si_cli" --kenlm tune "$si_model" "$si_dataset" > "$si_run/tuning.json"
for si_mode in test strict; do
    "$si_cli" --kenlm "$si_mode" "$si_model" "$si_dataset" "$si_run/tuning.json" > "$si_run/$si_mode.json"
done
"$si_cli" --kenlm english-final "$si_model" "$si_dataset" "$si_run/english-grid.json" "$si_run/tuning.json" > "$si_run/english.json"
"$si_cli" --kenlm hard "$si_model" "$si_dataset" eval/ranking/hard-cases.tsv "$si_run/english-grid.json" "$si_run/tuning.json" > "$si_run/hard.json"
```

### Frozen recall results

Class percentages use missed clauses in the same length bucket. Overall recall is 3,766 / 8,003.

| Gold characters | Queries | Misses | Missing word | Reading mismatch | Search pruning | Decoder limits |
| --- | --- | --- | --- | --- | --- | --- |
| 1–8 | 4,772 | 2,122 | 0 (0.00%) | 0 (0.00%) | 2,086 (98.30%) | 36 (1.70%) |
| 9–16 | 2,426 | 1,403 | 0 (0.00%) | 0 (0.00%) | 1,375 (98.00%) | 28 (2.00%) |
| 17–32 | 766 | 673 | 0 (0.00%) | 0 (0.00%) | 360 (53.49%) | 313 (46.51%) |
| 33+ | 39 | 39 | 0 (0.00%) | 0 (0.00%) | 0 (0.00%) | 39 (100.00%) |
| All | 8,003 | 4,237 | 0 (0.00%) | 0 (0.00%) | 3,821 (90.18%) | 416 (9.82%) |

| Evidence | 1–8 | 9–16 | 17–32 | 33+ | All |
| --- | --- | --- | --- | --- | --- |
| Beam or terminal cap | 1242 | 693 | 170 | 0 | 2105 |
| 32-row lexical cap | 844 | 682 | 190 | 0 | 1716 |
| 64-letter input cap | 0 | 0 | 306 | 39 | 345 |
| Output byte cap | 0 | 0 | 0 | 0 | 0 |
| Syllable cut or word span restriction | 36 | 28 | 7 | 0 | 71 |

All gold source tokens in the missed clauses occur in the compiled dictionary. 2,710 of 4,237 misses (63.96%) contain a gold token with multiple readings. Each has stronger evidence of a search or decoder restriction under the frozen spelling. The sampling method and lack of independent contextual pronunciations limit conclusions about reading quality.

Up to ten actual examples for each populated class and length bucket are in
`.build/kenlm-ranking-diagnostics/recall-examples.md` and `recall.json`.
The zero-count groups have no examples. Every missed clause and its evidence
is retained in `recall-cases.jsonl` in the same directory.

### Expanded Chinese grid and frozen results

The development sweep evaluated 167 profiles on 45,676 queries. The best score under each LM weight is shown with every tied insertion cost.

| Chinese LM weight | Coverage off best cost(s) | Coverage off Top-1 | Coverage on best cost(s) | Coverage on Top-1 |
| --- | --- | --- | --- | --- |
| 0.05 | 28.85 | 42.86% | 28.85 | 45.13% |
| 0.1 | 28.85 | 42.99% | 28.85 | 45.46% |
| 0.15 | 28.85 | 42.90% | 28.85 | 45.63% |
| 0.25 | 22 | 43.11% | 28.85 | 45.96% |
| 0.5 | 22 | 42.94% | 28.85 | 45.94% |
| 1 | 16 | 39.36% | 28.85 | 44.89% |
| 2 | 4 | 32.27% | 28.85 | 42.13% |

Neither maximum is below 0.25. The two maxima are unique. With coverage off
the selected cost is 22 bits. With coverage on it is 28.85 bits. Full grid
counts, selected profiles and all co-leaders are in `tuning.json`.

Accuracy cells show **Top-1 / Top-5**. All Chinese frozen accuracy and recall
counts match the preceding round. The selected parameters are the same.

| Track / gold characters | Queries | Pool recall | Legacy | Coverage only | Insertion only | LM | LM + coverage |
| --- | --- | --- | --- | --- | --- | --- | --- |
| All frozen queries | 30,544 | 64.94% | 41.69% / 56.92% | 43.94% / 57.82% | 41.69% / 56.92% | 43.06% / 58.97% | 45.56% / 59.48% |
| Whole clause | 8,003 | 47.06% | 30.33% / 43.33% | 33.44% / 44.61% | 30.33% / 43.35% | 31.06% / 44.70% | 34.40% / 45.57% |
| Whole clause, 1–8 | 4,772 | 55.53% | 37.51% / 51.47% | 40.88% / 53.00% | 37.51% / 51.47% | 37.91% / 52.89% | 41.91% / 53.81% |
| Whole clause, 9–16 | 2,426 | 42.17% | 24.28% / 38.25% | 27.82% / 39.37% | 24.28% / 38.29% | 25.47% / 39.82% | 28.65% / 40.85% |
| Whole clause, 17–32 | 766 | 12.14% | 6.27% / 10.97% | 6.53% / 11.23% | 6.27% / 10.97% | 7.70% / 11.36% | 7.57% / 11.49% |
| Whole clause, 33+ | 39 | 0.00% | 0.00% / 0.00% | 0.00% / 0.00% | 0.00% / 0.00% | 0.00% / 0.00% | 0.00% / 0.00% |
| Random short span | 8,003 | 71.15% | 47.58% / 62.86% | 49.24% / 63.64% | 47.58% / 62.86% | 47.81% / 64.25% | 50.38% / 64.75% |
| Random short span, 1–8 | 7,799 | 70.74% | 47.22% / 62.34% | 48.87% / 63.10% | 47.22% / 62.34% | 47.48% / 63.73% | 49.88% / 64.19% |
| Random short span, 9–16 | 203 | 86.70% | 61.58% / 82.76% | 64.04% / 84.24% | 61.58% / 82.76% | 60.10% / 84.24% | 69.46% / 86.21% |
| Random short span, 17–32 | 1 | 100.00% | 0.00% / 100.00% | 0.00% / 100.00% | 0.00% / 100.00% | 100.00% / 100.00% | 100.00% / 100.00% |
| Matched span without context | 7,269 | 71.36% | 44.70% / 61.12% | 46.80% / 61.89% | 44.70% / 61.12% | 45.70% / 62.46% | 47.56% / 62.79% |
| Matched span without context, 1–8 | 7,117 | 71.04% | 44.30% / 60.64% | 46.41% / 61.42% | 44.30% / 60.64% | 45.27% / 61.99% | 47.07% / 62.29% |
| Matched span without context, 9–16 | 150 | 86.00% | 63.33% / 83.33% | 65.33% / 84.00% | 63.33% / 83.33% | 65.33% / 84.00% | 70.00% / 86.00% |
| Matched span without context, 17–32 | 2 | 100.00% | 50.00% / 100.00% | 50.00% / 100.00% | 50.00% / 100.00% | 100.00% / 100.00% | 100.00% / 100.00% |
| Matched span with context | 7,269 | 71.36% | 44.70% / 61.12% | 46.80% / 61.89% | 44.70% / 61.12% | 48.40% / 65.37% | 50.56% / 65.70% |
| Matched span with context, 1–8 | 7,117 | 71.04% | 44.30% / 60.64% | 46.41% / 61.42% | 44.30% / 60.64% | 48.03% / 64.99% | 50.13% / 65.28% |
| Matched span with context, 9–16 | 150 | 86.00% | 63.33% / 83.33% | 65.33% / 84.00% | 63.33% / 83.33% | 65.33% / 83.33% | 70.00% / 85.33% |
| Matched span with context, 17–32 | 2 | 100.00% | 50.00% / 100.00% | 50.00% / 100.00% | 50.00% / 100.00% | 100.00% / 100.00% | 100.00% / 100.00% |
| Strict subset | 30,841 | 63.85% | 37.41% / 58.04% | 44.99% / 60.44% | 37.41% / 58.04% | 38.61% / 60.23% | 45.17% / 62.04% |

| P50 / P95 in ms | Legacy | Coverage only | Insertion only | LM | LM + coverage |
| --- | --- | --- | --- | --- | --- |
| All frozen queries | 3.48 / 16.56 | 3.57 / 16.67 | 3.57 / 16.64 | 3.98 / 17.24 | 3.98 / 17.22 |
| Whole clauses | 7.59 / 24.84 | 7.68 / 25.00 | 7.66 / 24.95 | 8.13 / 25.72 | 8.13 / 25.72 |
| Whole clauses, 1–8 | 4.97 / 10.37 | 5.04 / 10.49 | 5.03 / 10.48 | 5.49 / 11.36 | 5.50 / 11.36 |
| Whole clauses, 9–16 | 15.21 / 22.90 | 15.30 / 23.00 | 15.29 / 22.98 | 15.76 / 23.89 | 15.76 / 23.88 |
| Whole clauses, 17–32 | 23.93 / 34.02 | 24.03 / 34.34 | 24.03 / 34.32 | 24.35 / 35.07 | 24.35 / 35.08 |
| Whole clauses, 33+ | 0.02 / 0.02 | 0.02 / 0.02 | 0.02 / 0.02 | 0.02 / 0.02 | 0.02 / 0.02 |
| Strict subset | 9.80 / 21.57 | 9.88 / 21.69 | 9.87 / 21.67 | 10.24 / 22.31 | 10.24 / 22.30 |

These are in-process timings from the local Release benchmark with lazy mapping.
The run shared the machine with other diagnostic work.

### English dictionary audit results

Of 70,666 alphabetic keys, 33,760 admit a two-word split. There are 39,476 splits. The audit enables coverage and uses the legacy English penalty with both LM weights zero.

| Mode | Top-1 is the whole word | Top-1 is different | Split winner | Other English winner | Other winner |
| --- | --- | --- | --- | --- | --- |
| English only | 33,383 (98.88%) | 377 (1.12%) | 109 | 268 | 0 |
| Bilingual | 32,397 (95.96%) | 1,363 (4.04%) | 95 | 211 | 1,057 |

The 200 lowest-ratio words include 105 of the 109 English-only split winners. This concentration supports reviewing the split-frequency imbalance in that group. A two-word decomposition alone is a poor failure predictor across the full dictionary.

All weights and splits are in `english-splits.tsv`. The distinct-word
review list, with the most extreme split and actual first candidates, is
in `english-suspects-top200.tsv`. Neither dictionary was changed.

### English insertion grid and validation

Development grid. Cells show **Top-1 / Top-5**. The final column is the
mean Top-1 used to select the cost.

| English cost (bits) | Original whole | Original prefix | Generated guards | Mean Top-1 |
| --- | --- | --- | --- | --- |
| 24 | 96.63% / 99.66% | 31.31% / 72.05% | 98.85% / 100.00% | 75.60% |
| 28 | 96.97% / 99.66% | 33.00% / 69.70% | 99.39% / 100.00% | 76.45% |
| 30 | 96.97% / 99.66% | 31.99% / 67.34% | 99.19% / 100.00% | 76.05% |
| 32 | 96.97% / 99.33% | 31.65% / 67.34% | 98.71% / 99.80% | 75.78% |
| 33.182 | 96.30% / 99.33% | 30.98% / 65.32% | 98.17% / 99.66% | 75.15% |
| 34 | 96.30% / 98.65% | 30.64% / 64.31% | 97.90% / 99.66% | 74.95% |
| 35 | 96.30% / 98.32% | 29.97% / 63.30% | 97.63% / 99.53% | 74.63% |
| 36 | 96.30% / 97.98% | 29.63% / 63.30% | 97.29% / 99.26% | 74.41% |
| 37 | 96.30% / 97.98% | 29.63% / 63.30% | 96.82% / 99.12% | 74.25% |
| 38 | 95.29% / 97.64% | 29.63% / 61.62% | 96.14% / 98.92% | 73.69% |
| 40 | 93.94% / 97.64% | 27.95% / 61.28% | 95.33% / 98.65% | 72.40% |
| 42 | 92.93% / 96.97% | 26.94% / 59.60% | 94.04% / 98.10% | 71.30% |
| 46 | 90.24% / 96.30% | 26.26% / 57.91% | 91.81% / 97.43% | 69.44% |
| 50 | 87.88% / 95.29% | 25.59% / 57.24% | 90.45% / 97.09% | 67.97% |

The unique selected English cost is 28 bits. The generated guard set has 1,477 development and 961 held-back words. The held-back original benchmark has 203 whole words and the corresponding 203 prefixes.

| Held-back English cost (bits) | Original whole | Original prefix | Generated guards |
| --- | --- | --- | --- |
| 33.182 | 98.03% / 100.00% | 35.96% / 70.44% | 97.92% / 99.69% |
| 28 | 99.51% / 100.00% | 34.48% / 76.85% | 99.69% / 100.00% |

Full original English regression, including its development portion. Both
providers are enabled and English LM is zero. All accuracy cells are **Top-1 / Top-5**.

| Track / weight | Queries | Pool recall | Legacy | Coverage only | Chinese LM | Chinese LM + coverage | Chinese selected LM + coverage | Coverage + tuned English cost | Selected Chinese LM + coverage + tuned English cost |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Whole | 500 | 100.00% | 92.60% / 98.60% | 97.00% / 99.60% | 87.60% / 97.80% | 95.60% / 99.20% | 99.00% / 99.80% | 98.00% / 99.80% | 98.20% / 100.00% |
| Whole, 0–9 | 100 | 100.00% | 84.00% / 96.00% | 94.00% / 99.00% | 75.00% / 94.00% | 92.00% / 99.00% | 97.00% / 99.00% | 94.00% / 99.00% | 94.00% / 100.00% |
| Whole, 10–99 | 100 | 100.00% | 89.00% / 97.00% | 94.00% / 99.00% | 86.00% / 96.00% | 94.00% / 97.00% | 99.00% / 100.00% | 98.00% / 100.00% | 99.00% / 100.00% |
| Whole, 100–999 | 100 | 100.00% | 94.00% / 100.00% | 99.00% / 100.00% | 89.00% / 99.00% | 97.00% / 100.00% | 99.00% / 100.00% | 98.00% / 100.00% | 98.00% / 100.00% |
| Whole, 1000–9999 | 100 | 100.00% | 98.00% / 100.00% | 99.00% / 100.00% | 93.00% / 100.00% | 98.00% / 100.00% | 100.00% / 100.00% | 100.00% / 100.00% | 100.00% / 100.00% |
| Whole, 10000+ | 100 | 100.00% | 98.00% / 100.00% | 99.00% / 100.00% | 95.00% / 100.00% | 97.00% / 100.00% | 100.00% / 100.00% | 100.00% / 100.00% | 100.00% / 100.00% |
| Prefix | 500 | 100.00% | 19.80% / 54.20% | 33.00% / 67.40% | 15.60% / 48.00% | 30.80% / 63.80% | 35.20% / 73.40% | 33.60% / 72.60% | 35.40% / 75.40% |
| Prefix, 0–9 | 100 | 100.00% | 10.00% / 39.00% | 27.00% / 60.00% | 8.00% / 33.00% | 23.00% / 58.00% | 28.00% / 66.00% | 27.00% / 63.00% | 27.00% / 65.00% |
| Prefix, 10–99 | 100 | 100.00% | 19.00% / 39.00% | 27.00% / 52.00% | 15.00% / 35.00% | 25.00% / 52.00% | 28.00% / 55.00% | 27.00% / 53.00% | 28.00% / 55.00% |
| Prefix, 100–999 | 100 | 100.00% | 18.00% / 54.00% | 29.00% / 68.00% | 18.00% / 49.00% | 28.00% / 62.00% | 30.00% / 72.00% | 25.00% / 72.00% | 26.00% / 75.00% |
| Prefix, 1000–9999 | 100 | 100.00% | 19.00% / 61.00% | 28.00% / 69.00% | 13.00% / 54.00% | 27.00% / 65.00% | 33.00% / 81.00% | 32.00% / 80.00% | 34.00% / 86.00% |
| Prefix, 10000+ | 100 | 100.00% | 33.00% / 78.00% | 54.00% / 88.00% | 24.00% / 69.00% | 51.00% / 82.00% | 57.00% / 93.00% | 57.00% / 95.00% | 62.00% / 96.00% |

| English P50 / P95 in ms | Legacy | Coverage only | Chinese LM | Chinese LM + coverage | Chinese selected LM + coverage | Coverage + tuned English cost | Selected Chinese LM + coverage + tuned English cost |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Whole | 1.93 / 9.60 | 1.99 / 9.74 | 2.06 / 9.74 | 2.08 / 9.79 | 2.08 / 9.79 | 1.99 / 9.74 | 2.09 / 9.80 |
| Prefix | 1.46 / 5.83 | 1.55 / 5.96 | 1.59 / 6.09 | 1.62 / 6.13 | 1.64 / 6.13 | 1.56 / 5.95 | 1.65 / 6.14 |

### Authored probes

| Input | Target | Legacy cost, coverage | Tuned cost, coverage | Tuned cost, both experiments | Tuned result |
| --- | --- | --- | --- | --- | --- |
| `goon` | `go on` | `goon` | `go on` | `go on` | Pass |
| `into` | `into` | `into` | `into` | `into` | Pass |
| `also` | `also` | `also` | `also` | `also` | Pass |
| `maybe` | `maybe` | `maybe` | `maybe` | `maybe` | Pass |
| `cannot` | `cannot` | `can not` | `can not` | `can not` | Fail |
| `myself` | `myself` | `myself` | `myself` | `myself` | Pass |

Lowering the cost favors English results in bilingual competition and makes
additional English splits cheaper. It recovers `go on` and leaves
`cannot` below `can not`. The two words did not drive grid selection.

### Validation

| Step | Swift tests passed | Debug build |
| --- | --- | --- |
| Expanded Chinese grid | 453 | Passed |
| Frozen recall probe | 454 | Passed |
| English insertion cost and grid | 455 | Passed |
| Combined evaluation and final integration | 455 | Passed |

Verified SHA-256 equality for the frozen query files, source train and heldout
texts, both compiled dictionaries, the train-only model and both final binaries.
The English score test covers a direct word, a split, a mixed path and
an unaffected Chinese candidate. The recall probe test covers beam-free
reachability, lexical truncation and input limits. Live host behavior was
outside these in-process measurements.

## Production KenLM ranking

Current delivery selects the November 9 raw-text-v2 **0012** full-data refit
without Wikipedia (206.08 MiB). Local installation and release packaging use
`.build/kenlm-raw-text-v2-no-wikipedia-p0012/final/` and embed the model before
signing. See [the current model record](docs/KENLM_MODEL.md). The measurements
below retain the preceding train-only ranking study; they are not new-model
measurements.

Debug and Release now use the same preset. It enables full-coverage ordering,
uses Chinese LM weight 0.25, Chinese insertion cost 28.85 bits, English
insertion cost 28 bits, English LM weight zero and frequency weight 1. The
independent English grid selected 28 bits. With the selected Chinese LM and
coverage active, that choice moves English whole-word Top-1 from 99.00% to
98.20%, whole-word Top-5 from 99.80% to 100.00%, and prefix Top-5 from 73.40%
to 75.40% on the train-only benchmark.

The DMG installer and Sparkle update ZIP contain the full-data model under
`SI.app/Contents/Resources/KenLM/`. Packaging verifies the model's SHA-256
and size before signing the app. It includes the model compatibility record,
KenLM notices and the pinned corpus source and license notices. The binary
at the original packaging checkpoint was the quantized full-data model documented above,
trained on LCCC, mC4, Kubernetes, TensorFlow, MDN and Chinese Wikipedia.
The current replacement uses the seven non-Wikipedia sources listed in the
current model record. Each
source retains its own terms in the bundled corpus notices.

The separate install command remains available for source builds. It verifies
and installs the same model into a versioned App Support directory.

```sh
corpus/.venv/bin/python scripts/install_kenlm_model.py
```

The app prefers the bundled model. It checks metadata and file size, then
opens the signed resource on a worker. The App Support fallback additionally
checks its installation manifest and file stamps. If the model is missing,
invalid or still loading,
coverage and the English insertion cost work with dictionary scores.
Provisional results and explicit actions that must resolve pending candidates
also use those dictionary scores. Normal full results use the model when
available. Secure event input keeps legacy ranking. The old development
ranking switches and saved preferences are removed.

Automatic prefix confirmation remains opt-in. Candidates within the
confidence margin under either the legacy or adjusted score must agree on
the exact prefix boundaries before automatic confirmation.

KenLM can score Chinese candidates using up to three preceding tokens. In
the train-only paired-span experiment, explicit gold context improved
Top-1 from 47.56% to 50.56% on 7,269 queries. Production starts from the
current composition and reads no surrounding host text. The paired result
does not measure the effects of segmenting live field text.

Validation used the installed model for the full Swift suite. All 458 tests
passed, and both unsigned Debug and Release app builds succeeded. The model
and no-model paths were checked separately. Live input-method behavior in
host apps remains unverified.
