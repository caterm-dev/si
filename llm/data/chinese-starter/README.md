# Chinese starter corpus v1

**Historical record.** The current editable source is [../csv/](../csv/README.md). Its CSV files were materialized once from this dataset and now replace seed/template generation in normal preparation. The commands/counts below describe the original experiment; retain them only for reproduction of old runs.

`seed.json` contains original SI-authored common-vocabulary candidates, short chat messages, phrase templates and reviewed pronunciation overrides. It does not copy a dictionary, web corpus, chat log, user phrase archive or personal history. It retains the repository's GPLv3 license. Pronunciation generation uses pinned pypinyin 0.55.0 (MIT), including explicitly listed polyphonic alternatives.

The generated corpus has **1,544 unique vocabulary entries** (including common single characters and short expressions), **4,697 unique chat/template outputs**, and **6,238 unique Chinese outputs overall**. Some entries occur in both categories. There are 6,248 distinct spelling/output pairs; 6,255 source rows retain overlapping group memberships. Chinese output is at most **11 characters** in this version; the generator enforces an editable upper bound of 16. This is a curated synthetic starter, not a measured frequency-ranked vocabulary or a representative real-chat benchmark.

Topics include people/family, time, locations, daily activities, food, household objects, work/technology, politeness, meeting plans, requests and short status messages. For example:

| Input | Target |
| --- | --- |
| `nihao` | 你好 |
| `womenzaijia` | 我们在家 |
| `womingtianqugongsi` | 我明天去公司 |
| `yaobuyaoyiqichifan` | 要不要一起吃饭 |
| `wodeixianqumangle` | 我得先去忙了 |
| `yinhang` | 银行 |
| `chang` / `zhang` | 长 |

Readings are generated deterministically, with phrase overrides for cases such as 银行、行业、音乐、重庆、便宜 and 得先. Overrides and a small set of alternate single-character readings are explicit in the seed. These checks do not establish perfect pronunciation of every automatically generated phrase; review corrections in the seed before creating the next corpus version.

## Reproduce and edit

From the repository root, after setup:

```sh
./llm/scripts/generate_data.sh --output llm/data/raw/chinese-starter-v1
./llm/scripts/prepare.sh --config llm/configs/0.4b-chinese-starter-v1.json \
  --sources llm/configs/sources.chinese-starter-v1.json \
  --output llm/data/prepared/chinese-starter-v1
```

The raw directory contains `pairs.jsonl`, a standalone source manifest, generation counts/hashes, a notice and GPL license. The registered config manifest additionally includes the existing 92 synthetic workflow pairs to retain a small English/identifier/mixed sample. The generated raw/prepared directories are ignored by Git; the seed, generator, training config and checksum-pinned registration are retained in source. Reproduction with the same seed/generator and pinned pronunciation tool produces the same bytes. Existing output directories are never overwritten by these commands.

Edit word/message categories or individual template slots in `seed.json`, then generate a **new output directory**. Update/copy the source registration with the new pair hash and revision from the generated `sources.json`; paths in the registered config are relative to `llm/configs/`. Prepare a new dataset version and start a new experiment. Do not edit data or training code during an active run and expect to resume it under the same identity.

Templates declare `group_by` slots and optional shared `family` names. Related person/time variants of the same location/action/food stay in one clean group before splitting. Duplicate target/input spellings also merge groups, including overlaps with the old fixtures. These checks prevent exact/grouped leakage, but generated test phrases are still synthetic and may share broader linguistic structure with training data.

Preparation retains clean pairs and adds up to two one-edit keyboard variants after splitting, using deletion, duplicate insertion, neighboring-key substitution and adjacent transposition. Cross-split synthetic input collisions are discarded. The current prepared version contains:

| Split | All rows | Clean rows |
| --- | ---: | ---: |
| Train | 16,313 | 5,439 |
| Validation | 1,361 | 454 |
| Test | 1,300 | 436 |
| Total | 18,974 | 6,329 |

Thirteen conflicting synthetic variants were discarded. Normalized input, target and group identities are disjoint across splits. The train-only vocabulary has lossless byte fallback for unseen validation/test characters. The test split remains excluded from training and checkpoint selection. The small English/mixed supplement is not sufficient to establish bilingual model quality.

## Initial 0.4B experiment

`configs/0.4b-chinese-starter-v1.json` preserves the **403,069,952-parameter** architecture. It uses FP32, batch size 2, accumulation 4, activation checkpointing, a 100-step warmup and a 2,000-step first stage. Validation loss is computed every 100 steps; checkpoints are saved every 25. This is an initial from-scratch training stage, not a claim of convergence or daily-use conversion quality.

The first local MPS run was started on October 26, 2026. Artifacts are under `llm/runs/chinese-starter-v1/`; scalar console output is in `llm/runs/chinese-starter-v1.log`. Inspect the live log/metrics and process state for current progress rather than treating this prose as live status. No trained model is integrated into SI.

Its first validation exposed a PyTorch 2.6 MPS shape assertion after step 99. Equivalent full attention masks fixed the variable-length replay and matched CPU numerical checks. The original step-75 optimizer checkpoint is retained as `last-before-mps-mask-fix.pt`; a one-off compatible code-identity repair is documented in `recovery.json` and `run.json`, with weights/optimizer/RNG preserved. Training was resumed from that step. This recovery does not relax the normal strict resume checks.

The resumed full-sized model completed validation at step 100 with token cross-entropy **3.9344046882**, wrote `best.pt`/`last.pt`, and continued beyond step 160. This is a startup verification record; it does not measure candidate accuracy or imply that the 2,000-step stage has finished. `llm/reports/chinese-starter-v1-startup.json` records that first successful validation and checkpoint identity.

For the same unchanged experiment after it has stopped:

```sh
./llm/scripts/resume.sh --config llm/configs/0.4b-chinese-starter-v1.json \
  --data llm/data/prepared/chinese-starter-v1 --run llm/runs/chinese-starter-v1 \
  --device mps --threads 4
```

Do not start a concurrent trainer against the same run directory. The first 2,000 steps process approximately one pass of this augmented training set; larger and more representative data plus independent conversion/real-typo evaluation are still required. Training loss alone is not an accuracy or robustness result.
