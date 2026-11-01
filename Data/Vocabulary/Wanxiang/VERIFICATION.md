# Initial Wanxiang migration verification — October 29, 2026

This records the initial source migration. Later on the same date, imported CSV prefixes were removed and local category weights/defaults became 10; see the current [testing record](../../../docs/TESTING.md#category-filenames-and-local-weight-defaults).

## Initial scope

The source is `amzxyz/rime-wanxiang-data`, pinned to
`adfa047c339627737f0a4c75674a8042c1ef7f72`. All 14 normal simplified dictionaries
are included; `abbrev`, `t9_abbrev`, `cuoyin` and `mixed` are excluded.

Chinese `zi`/`jichu`/`duoyin` produce a 1,547,554-entry base; ten other Chinese
files remain separate `wanxiang_*.csv` categories (602,516 rows). English `en`
produces a 72,784-entry base. The eight preexisting Chinese category CSVs and two
preexisting English category CSVs match their pre-migration SHA-256 values byte
for byte. Those values are retained in the conversion report and metadata.

Final merged resources contain 2,142,230 Chinese entries (191,250,432 bytes) and
74,337 English entries (7,307,264 bytes). The Chinese resource is larger than its
former 83,521,536 bytes; no size or latency improvement is claimed. Base weights
take precedence, followed by imported category weights and local supplements.
The resource unit is `si-wanxiang-weight-v1`, reference mass and unknown weight
one. Old resource units are rejected.

Known source examples: `but` = 347,086; `不 / bu` = 510,341; `过 / guo` = 342,847;
`国 / guo` = 19,975; `呢 / ne` = 824,128.

## Checks actually run

Complete source files were downloaded from the pinned revision and checked before
conversion. The new fetch command was also exercised with 13 cached files and
one missing small source (`fangyan`); it downloaded that source and verified all
14. Conversion/check commands used `--source-dir` with the verified cache.

| Check | Result |
| --- | --- |
| `wanxiang_dictionary.py fetch` | Real download and cache validation passed |
| `wanxiang_dictionary.py convert` / `convert --check` | Both bases, ten classifications, metadata and report reproduced offline |
| `csv_dictionary.py build` / `build --check` | Both resources generated; source metadata, schema, indexes and exact rows checked |
| `msime_dictionary.py build --check` | Chinese dictionary and unchanged context artifacts passed |
| `python3 -m unittest discover -s Tests/VocabularyTests -v` | 39 tests passed |
| `./scripts/test.sh` | 405 Swift tests passed across all five test targets |
| `./scripts/build.sh` | Final Debug build passed, signing disabled |
| `python3 scripts/ranking.py --check` | Historical attribution and synthetic calibration passed |
| Final source/category/license/manifest audit | All normal sources accounted for; original categories, bundled licenses and runtime checksums matched |
| Local documentation links and `git diff --check` | Passed |

Test/build commands initially failed inside the execution sandbox because
SwiftPM/Xcode could not access compiler caches or apply their own sandbox. They
passed when rerun in the normal development environment. The initial environment
failure was not counted as a code failure or a passing check.

## Regression updates and limits

Dataset-specific expected weights, casing and candidates now follow Wanxiang.
Four Chinese score oracles were independently recomputed in Python from the SQL
weights and unchanged ngram binaries, then checked against Swift results.
One-letter rendering uses an explicit candidate fixture. Automatic-confirmation
positives use an explicit boundary where the newly imported English `peng`
otherwise activates tail protection; a new regression checks both behaviors.
No tests were removed, and no scoring, beam, language-transition or confirmation
policy was retuned to restore old data-specific rankings.

The report lists all 19 English forms excluded by the existing printable-ASCII
contract. Missing weights remain zero (355 Chinese rows, 226 English rows);
73 numeric suffixes use their numeric prefix. Tone/case collisions retain maximum
supplied weights, not summed counts. The English source omits standalone `a` and
`ma`, and uses `gmail` rather than `Gmail`; exact original input remains available.

No input method was installed, launched or restarted. Live host positioning,
focus changes, shortcuts, mouse/number selection and spoken VoiceOver remain
unverified. No independent quality evaluation or latency benchmark was performed.
Source equality does not establish Rime decoder parity, calibrated bilingual
probabilities or improved conversion quality. Existing unrelated worktree changes
were preserved; no commit or publication was performed.
