# Implementation verification — 2026-10-18

This records the current implementation checkpoint, not a stable-release certification. The overall daily-use input-method objective remains open.

## Provisional hints during continuous typing — 2026-10-20

Continuous edits could keep every completed full-search result obsolete. The panel then retained old rows until the user paused. The controller now runs a coalescing provisional lane on a separate worker actor alongside the existing full-search lane. Both use revision-checked immutable requests and the same engine; the provisional mode bounds lexical edges rather than adding another decoder. Current hints refresh pending rows without hiding or shrinking the panel, while selection/page/expansion actions remain disabled. Full confirmation still resolves current final candidates; literal/cancel/focus boundaries invalidate both lanes without waiting. Provisional identity remapping cannot commit or train a candidate absent from the final result. Final lexical completeness and search budgets remain unchanged.

The complete test run passed 205 methods (144 core, 31 presentation, 18 settings, 12 storage). Coverage includes a deliberately blocked obsolete full search while current hints update, duplicate/stale/cross-client and consent/configuration rejection, full-before-preview delivery, literal commits without provider calls, exact prefix remainder confirmation, deleting the last character, personal-phrase learning exclusions, and pending-row replacement in both layouts. The workspace's preview-quality regressions also check high-scoring homophones before fanout limits. The universal Debug build and shell/whitespace checks passed. No installation, process restart, input-source change or live host-app operation was performed; native key-to-screen responsiveness, focus/positioning and VoiceOver remain unverified.

The reproducible optimized `./scripts/benchmark.sh --previews` run uses the same eighteen synthetic scenarios, 5,000 aggregate preferences and up to 1,000 personal phrases, with ten warmups and 200 iterations per scenario. The short, ambiguous, incomplete, phrase-construction and mixed scenarios measured 0.041, 0.022, 0.054, 0.488 and 0.363 ms median respectively. Long ambiguous input measured 7.829 ms median/8.066 ms p95; dense known input 9.137/9.759 ms; dense input with an unknown tail 7.956/8.338 ms; long personal expansions 7.228/7.339 ms; Unicode personal expansions 16.155/17.347 ms. First engine initialization measured 421.654 ms. These are bounded provisional engine computations, excluding actor scheduling, competing full searches, IPC, rendering and host events. Their smaller output is not equivalent to full search, and these figures do not establish a native latency target or eliminate synchronous confirmation waits. The ordinary benchmark mode still measures final generation and typing edits.

## Compact candidate strip and featured prefixes — 2026-10-20

The input window now starts as a horizontal, three-choice strip with an accessible expansion chevron. Expanded mode shows nine vertical choices per page and retains a collapse control even for one page. Layout changes preserve the selected candidate; page keys, scrolling, displayed digits and mouse choices use the same layout-dependent page. Composition end resets expansion. Both layouts retain existing rows/size and disable actions, including expansion, during pending searches.

The presentation list features the first two whole candidates and up to seven prefixes ranked with the session's consumed-spelling learning/context score, then retains every other result in engine order. Core generation and Settings preview ordering are unchanged. This brings word/character confirmation ahead of many sentence variants without removing whole, mixed, other-language or literal alternatives. It does not implement sentence semantics or internal context scoring.

`./scripts/test.sh` passed all 197 test methods (138 core, 29 presentation, 18 settings, 12 storage), including compact/expanded pending-search and language/literal-paging cases. New coverage checks layout switching with a later selected candidate, visible number/mouse agreement, reset, narrow-screen bounds, featured-prefix ordering, consumed-spelling learning and exact prefix remainder commits. `./scripts/build.sh` passed for the universal Debug app; the only warning was the existing skipped AppIntents metadata extraction. Whitespace checks passed. Light/dark offscreen renders of both layouts using synthetic `nengxiangbanfayouhuama` were visually inspected. No installation, SI restart, input-source change or host-app operation was performed. Live host event routing, focus/positioning, actual VoiceOver interaction and automatic appearance changes remain unverified; follow [TESTING.md](TESTING.md).

## Three English technology sources — 2026-10-20

The user authorized adding CSpell software tools, CSpell companies, and Rime Ice's `en_ext` English extension together. Their pinned snapshots and package/source-specific MIT/GPLv3 notices now feed the existing offline generator and shared English Trie. See [source versions, selection and license review](ENGLISH_VOCABULARY.md#technology-sources-and-selection). The accepted source sizes are 572, 718 and 1,447 respectively. They add 2,386 unique spellings, bringing the merged vocabulary from 61,216 to 63,602. A complete comparison with the previous merged table found no change to the casing or completion score of any pre-existing word. New-source completions score 75, and an explicit durable override converts upstream `GMail` to `Gmail`.

The maintenance-only `cspell` adapter handles whitespace-delimited inline annotations while rejecting unsupported complete rows, including compound markers, punctuation, numbers, spaces and non-comment tab fields. Existing plain-word-list and Rime semantics are preserved. Rime imports still require matching output/code spelling and discard shortcut expansions/weights. The six registered English sources are covered by the existing upstream audit workflow without a new runtime dependency or timer.

Validation:

- `python3 -m unittest discover -s Tests/VocabularyTests -v`: 27 tests passed, including annotated imports, unsupported spelling preservation, pinned settings, durable casing overrides, checksums and failure preservation.
- `./scripts/test.sh`: 193 methods passed (138 core, 12 storage, 18 settings and 25 presentation). New cases cover exact/canonical/uppercase technology words from all three sources, `gm` completion, mixed `nihaogmail`, literal retention, disabled English and ordinary lowercase words. Full word/prefix Trie checks use the expanded vocabulary. The old unknown fixture `QwErTy` now contains lexical `QWERT`; the privacy fixture uses a genuinely unknown synthetic span and additionally checks an unknown tail after `Gmail`, including rejection of learning/context.
- Both English and Chinese offline `build --check` commands passed. Real HTTPS pinned refreshes of all three new sources reproduced merged word checksum `ce8cae1ea9660b4d42dfd297886a3aa98fea674ca8a13232289a3d707bfeb14b` and the same 63,602 words. Strict CSpell re-parsing also reproduces the checked-in snapshots.
- Debug and Release app builds passed with only the existing skipped AppIntents metadata warning. Each built bundle's English notice resource exactly matches the generated source. Local documentation links and whitespace checks passed.

Release before/after measurements use the same twenty synthetic cases, 5,000 aggregate preferences, 1,000 personal phrases, 10 search warmups and 200 search iterations. The baseline report began at `2026-10-20T03:20:45Z`; the expanded run began at `2026-10-20T03:26:42Z`, after builds/tests finished. Reports are retained locally at `.build/english-trie/tech-before.json` and `.build/tech-vocabulary/after.json`.

| Scenario | Before median (ms) | Expanded median (ms) | Expanded p95 (ms) |
| --- | ---: | ---: | ---: |
| English broad prefix | 0.932 | 0.984 | 1.025 |
| English prefix | 0.112 | 0.113 | 0.122 |
| English exact | 0.084 | 0.084 | 0.091 |
| mixed | 5.882 | 6.062 | 6.177 |
| dense known composition | 14.567 | 15.532 | 16.134 |
| dense prefix with unknown tail | 104.075 | 100.371 | 106.334 |

The broad-prefix engine case grows from 3,443 to 3,620 candidates; other counts/segmentations and some fingerprints also change with new words. Within the expanded run, synchronous/deferred final fingerprints match. These single-run comparisons do not claim a speed improvement or establish real-host latency. Initial default-engine preparation was 411.592 → 417.166 ms. CLI maximum RSS was 236,994,560 → 237,092,864 bytes, with peak footprints 229,999,240 → 230,081,160 bytes; these are process totals, not isolated index allocations or app memory.

No installation, input-source change, host-app operation, commit or push was performed for this vocabulary addition. Native typing, focus/shortcuts, candidate paging and accessibility remain unverified; the added manual cases in [TESTING.md](TESTING.md) are still required before release. The original input remains independently available, including unsupported source forms; newly recognized abbreviations can change bounded mixed decoding without establishing production coverage or statistical ranking.

## Combined responsiveness validation — 2026-10-20

The complete checkout includes the English Trie, bounded continuation selection, deferred/coalesced client-local requests, stable pending candidate panels, Release-default installation, and their regressions. `./scripts/test.sh` passed all 192 methods (137 core, 12 storage, 18 settings and 25 presentation). Debug and Release app builds passed with only the existing skipped AppIntents metadata warning. Installer shell syntax, local documentation links and whitespace checks passed. No installation or native host-app operation was performed; the manual compatibility and accessibility checks remain outstanding.

## English Trie and static entry metadata — 2026-10-20

Direct English lookup and the shared mixed decoder now use one immutable compact ASCII Trie. Nodes contain child bitmaps, packed child IDs and ranges into the sorted vocabulary; they do not copy completion lists. Each entry caches canonical/initial-capital/uppercase text, byte length, completion score and continuation cost. Mixed lookup advances a cursor per source start, retaining the original edge order, explicit apostrophe constraints and two-letter completion minimum. Learning/context adjustments remain query-local. No word sources, candidate caps, ranking rules, personal data or persisted schema changed. These derived structures initialize once on first default-engine construction and rebuild after process restart; no input cache or serialized index was introduced.

The performance measurements below were collected in the shared checkout with pre-existing continuation-pruning and deferred-typing changes. The English Trie commit (`9019bdd`) excluded those changes. Its benchmark had eighteen search cases; the comparison checkout additionally had two existing typing-edit cases.

Validation on Apple Silicon macOS 27.0.1, Xcode 27.1, Swift 6.4:

- The isolated staged snapshot passed all 178 tests (129 core, 12 storage, 18 settings and 19 presentation) and `./scripts/build.sh`. This verifies the committed English changes without the unrelated uncommitted work; the app build had only the existing AppIntents metadata warning.
- In the shared checkout, `./scripts/test.sh` passed 191 methods: 136 core, 12 storage, 18 settings and 25 presentation. The final `./scripts/test.sh --filter EnglishVocabularyTests` passed seven methods, including one additional mixed-boundary regression and expanded exhaustive prefix coverage. It checks all 61,216 words and 140,688 nonempty prefixes against source-derived expectations, source-list reference candidates/metadata, casing (including Unicode input that lowercases to ASCII), exact/completion separation, invalid prefixes and mixed boundaries.
- `./scripts/build.sh` passed. Its only warning was the existing skipped AppIntents metadata extraction. `./scripts/vocabulary.sh build --check`, local documentation links and whitespace checks passed. Existing unrelated work in the checkout was preserved.
- Before/after `./scripts/benchmark.sh --resources` runs used the same vocabulary, 5,000 synthetic preferences, 1,000 personal phrases, 10 warmups and 200 iterations per search scenario. Five English-only engine cases extend the original thirteen search cases; the two existing typing-edit cases remain separate. All twenty output counts/fingerprints match before and after. Builds/tests finished before measurement. Reports are retained locally under `.build/english-trie/`.

| Scenario | Before median (ms) | After median (ms) | After p95 (ms) |
| --- | ---: | ---: | ---: |
| English broad prefix | 1.314 | 0.914 | 0.980 |
| English prefix | 0.163 | 0.112 | 0.119 |
| English uppercase prefix | 0.143 | 0.111 | 0.128 |
| English exact | 0.128 | 0.082 | 0.090 |
| English missing prefix | 0.040 | 0.031 | 0.036 |
| mixed | 5.953 | 5.910 | 6.058 |
| dense known composition | 17.118 | 14.552 | 14.902 |
| dense prefix with unknown tail | 101.874 | 108.671 | 110.397 |

The first pair shows approximately 22–36% lower medians for these English-only engine scenarios, with limited benefit in several mixed/lattice workloads. Saved executables were then repeated in reverse order (after, then before), without builds/tests running. The English-only repeat medians were 1.309 → 0.930, 0.161 → 0.111, 0.140 → 0.110, 0.135 → 0.082 and 0.043 → 0.031 ms respectively. The unknown-tail repeat was 104.338 → 96.386 ms, so the initial slowdown was not consistent across runs; these two samples do not establish an improvement for that workload. All twenty output counts/fingerprints match across all four runs. The after-repeat benchmark produced complete JSON, but its `time -l` resource collector exited with a sandbox denial for `sysctl kern.clockrate`; resource comparisons here use the successful initial unsandboxed runs.

The first measured default-engine initialization took 399.735 ms before and 427.235 ms after (about 28 ms extra). The reverse-order repeat measured 405.315 ms before and 416.358 ms after (about 11 ms extra). Initialization includes preparation of both languages and is one sample per process, not total application startup. CLI maximum resident set size rose from 226,164,736 to 235,831,296 bytes (about 9.22 MiB); peak footprint rose from 219,169,416 to 228,835,976 bytes. These are whole-process resource totals, not isolated index allocations or input-method app memory. Candidate-generation measurements exclude InputMethodKit, IPC, UI delivery and host-app latency.

No installation, process termination, input-source change or host-app operation was performed. Actual host typing, shortcuts/focus, paging and appearance remain unverified; follow the existing manual checks before release. The Trie still enumerates complete direct matches and preserves exact literals and language ambiguity.

## Candidate-window continuity — 2026-10-20

The user reported per-keystroke flashing after deferred search was introduced. The pending-request branch explicitly ordered the panel out before every search. It now keeps the visible panel and its existing rows, dimensions and footer while waiting, then replaces the contents on accepted delivery. Pending mouse/page/scroll actions are blocked; keyboard confirmation still resolves the current spelling. The first search shows a literal placeholder, and a hidden panel starts with the new composition's contents. Showing an already visible panel no longer orders it front again or reapplies an unchanged frame. Commit, cancellation, deactivation and invalid geometry retain their dismissal behavior.

The directed run passed 49 tests (24 core and 25 presentation), including two new pending-view regressions, obsolete/queued row actions, deferred delivery, selection, placement, editing and prefix/boundary commits. The view checks are offscreen and do not display a window or control host apps. The Debug app build passed; its only warning was the existing skipped AppIntents metadata extraction. Whitespace checks passed. SI was not installed or restarted, and actual window continuity, VoiceOver and host-app behavior remain unverified until manual checks from [TESTING.md](TESTING.md). The prior rapid-typing checkpoint below describes the earlier implementation that hid pending rows.

## Rapid typing responsiveness — 2026-10-20

The user reported lag during fast typing. Inspection found that the installer always selected the unoptimized Debug app, and every composition edit synchronously generated candidates in the InputMethodKit main-thread callback. A Release benchmark with the maintained vocabularies reproduced expensive searches. A three-second sample of only the self-launched synthetic benchmark identified full continuation sorting as a hotspot; no input-method process or personal input was sampled.

Continuation selection now retains the same bounded distinct best paths incrementally rather than sorting the full incoming pool. State/beam budgets, canonical comparison/identity, stable tie order, prefix presentation, terminal scoring, and direct lexical/personal results remain intact. The input-method controller uses deferred `InputSession` requests: marked spelling updates before a shared worker actor computes candidates, and each client coalesces work to one in-flight request plus one latest replacement. Sealed, revision-checked results cannot restore edited/cancelled compositions or apply to another client. Delivery rechecks settings, consent, secure-input suppression, dictionary, and context. Return/Escape/shortcuts do not wait for candidates; selection and punctuation boundaries resolve current pending candidates synchronously to retain exact commit behavior. Old rows hide while pending, and removed row actions are rejected. No unsafe isolation bridge was added.

The installer now defaults to Release, with an explicit `Debug` argument for debugging. Its process guard, signing, backup, registration, and rollback behavior are unchanged. This repair did not install or terminate SI, alter enabled input sources, inspect private archives, or operate host apps.

Validation on Apple Silicon macOS 27.0.1, Xcode 27.1, Swift 6.4:

- The main directed run passed 154 tests (131 core and 23 presentation), including bounded/exhaustive search, Unicode, learning, prefixes, editing, selection, deferred results, and the production worker's off-main execution. A final focused run passed seven deferred-session methods and three pipeline methods, adding four independently injected learning/dictionary/context/secure configuration cases to the earlier checks. There are 155 distinct passing core/presentation methods across these runs. Controlled continuations test coalescing and replacement without timing sleeps. Storage/settings suites were not rerun beyond the existing directed scope.
- Debug and Release app builds succeeded. The only app-build warning was the existing skipped AppIntents metadata extraction. Installer shell syntax passed, and an invalid configuration exited with usage/status 2 before touching installation state. Whitespace checks passed.
- The baseline and final Release runs use 5,000 synthetic preferences, 1,000 personal phrases, 10 warmups and 200 iterations for the original thirteen search scenarios. Final measurement began at `2026-10-20T01:43:28Z` after builds/tests finished. All thirteen final candidate fingerprints match baseline. The brief CPU sample occurred during the baseline pass; fingerprint agreement and small exhaustive tests are regression evidence rather than a proof over all inputs.

| Candidate-generation scenario | Before median (ms) | Final median (ms) | Final p95 (ms) |
| --- | ---: | ---: | ---: |
| short | 5.325 | 5.291 | 5.358 |
| ambiguous | 1.662 | 1.687 | 1.727 |
| partial | 2.420 | 2.509 | 2.546 |
| phrase construction | 25.583 | 19.370 | 19.520 |
| mixed | 10.998 | 6.215 | 6.309 |
| long ambiguous composition | 167.617 | 61.027 | 61.530 |
| literal fallback beyond decoder limit | 0.009 | 0.009 | 0.011 |
| personal phrase prefix at full capacity | 10.713 | 10.666 | 10.838 |
| dense known composition | 21.665 | 16.643 | 16.822 |
| dense prefix with unknown tail | 111.346 | 98.442 | 99.627 |
| bounded long personal expansions | 30.411 | 23.196 | 23.430 |
| learned tokens in longer composition | 82.028 | 41.238 | 41.627 |
| bounded Unicode personal expansions | 104.712 | 62.759 | 63.157 |

The added 16-character typing-burst measurements compare the caller's synchronous and deferred edit work using the same optimized engine (3 warmups and 20 measured bursts). Synchronous edits took 183.945 ms median/184.760 ms p95 per burst; deferred edits took 0.009 ms median/0.009 ms p95. Deferred final resolution occurs outside the edit timer, and the final synchronous/deferred candidate fingerprints match. This measures only in-process session edits; it excludes actor scheduling, background search, marked-text IPC, drawing, settings access, and confirmation waits. It is not a native key-to-screen latency claim.

The final fifteen-scenario CLI took 78.79 seconds under `time -l`, with 227,426,304 bytes maximum resident set size and 220,430,984 bytes peak memory footprint. These are CLI-process totals, not input-method app memory or a startup measurement. Background searches still have the costs above; confirmation boundaries can wait for current search, and Settings preview remains synchronous. Actual fast typing, focus changes, shortcuts, secure fields, candidate delivery/paging, and appearance remain unverified in host apps and require the new checks in [TESTING.md](TESTING.md) after installing the Release update.

## Top menu-bar template badge — 2026-10-20

The user clarified that the missing background was in the top menu bar. Before this change, the source, Debug app, and installed normal/alternate TIFF files had matching hashes, and a read-only SI-bundle-filtered TIS query returned one SI source pointing to the installed `InputSourceIcon.tiff`. The installed metadata used `TISIconIsTemplate = false`. This rules out a missing file update, but does not identify the menu agent's actual rendering or cache state. The previous synthetic full-color preview was not evidence that the top menu bar rendered correctly.

The generator now creates one `InputSourceIconTemplate.tiff`: an opaque rounded badge with transparent SI glyph cutouts, using Core Text with destination-out blending. Bundle metadata marks it as a template and removes the alternate color bitmap. The new filename distinguishes the alpha mask from the former resources without changing the input-source identifier, language registration, connection, or preferences. This follows AppKit's template-image processing model; it remains a targeted visual repair rather than a confirmed diagnosis of the original menu-bar failure.

Generation and alpha inspection passed: the TIFF has 16×16 and 32×32 pixel representations with 16×16 point logical size, opaque badge interiors, transparent corners, and 42/160 sufficiently transparent letter pixels in the inspected inner regions. A simulated light/dark/selected tint preview at `.build/si-template-badge-preview.png` was visually inspected. This is alpha-mask compositing, not a system screenshot. The Debug app build succeeded with the existing AppIntents metadata warning. The built template hash matches the source, the built plist references it with template mode enabled and no alternate entry, and plist syntax/whitespace checks passed. No core tests, Release build, or benchmark was run for this asset/metadata change.

The user authorized a targeted input-menu inspection, but the native tool returned a connection-availability notice without app state or an image. No other control backend was used. The template update has not been installed, and no process was terminated, input source changed, or login session restarted. Actual top-menu rendering, selected-state tinting, dark/light appearance, and the input-source picker still require checking after installation.

## Chinese vocabulary maintenance — 2026-10-19

The initial Chinese import merges 8,757 annotated character readings and 76,827 base entries selected by upstream weight from Rime Ice revision `da1fbe602e38f26db846fa10120ee64c2b0324c0`, all 979 original SI entries, and three local additions. Deduplication produces 85,596 text/reading pairs and 84,880 distinct texts. This is a selected subset; the extension table and unannotated Tencent table are excluded. Source selection, weights, pins, SHA-256 values, original headers, GPLv3 license and THUOCL MIT notice are retained. The [Chinese workflow](CHINESE_VOCABULARY.md) adds source tracing, persistent reading corrections/exclusions, staged group refreshes and monthly upstream audits alongside English.

Validation on Apple Silicon macOS 27.0.1, Xcode 27.1, Swift 6.4:

- `./scripts/test.sh`: all 174 tests passed (125 core, 19 presentation, 12 storage, 18 settings). Focused coverage includes original text/reading/score preservation, imported polyphonic readings, mixed `字幕subtitle`, disabled languages, literal retention, dense completion alternatives, Chinese abbreviations inside English words and exhaustive terminal ranking across 16,384 synthetic combinations in two insertion orders.
- `python3 -m unittest discover -s Tests/VocabularyTests -v`: all 25 English/Chinese maintenance tests passed. Chinese checks include explicit readings, normalization, bounded frequency mapping, persistent corrections, checksums/headers, malformed or unannotated rows, unchanged files after a failed second table in a group, and language-specific audit commands.
- Both language `build --check` commands passed. A real pinned `refresh rime-ice` reproduced the selected snapshots and generated outputs. The real upstream audit confirmed both pins matched `main` at the time of checking. The workflow YAML was checked locally; the changed workflow has not been run on GitHub.
- Debug and Release app builds succeeded, with the existing skipped AppIntents metadata extraction warning. Both generated vocabulary notices were verified byte-for-byte in each app bundle.
- Local documentation links, shell syntax and whitespace checks passed.

The Release benchmark at `2026-10-19T14:26:40Z` used the existing thirteen synthetic scenarios, 5,000 aggregate preferences, 1,000 personal phrases, 10 warmups and 200 iterations. The before run in this session used the maintained English vocabulary and original 979 Chinese entries. The final run uses the expanded Chinese vocabulary, grouped reading indexes, separate bounded terminal completion states and incremental terminal selection.

| Scenario | Before median (ms) | Final median (ms) | Final p95 (ms) |
| --- | ---: | ---: | ---: |
| short | 0.200 | 5.337 | 5.491 |
| ambiguous | 0.269 | 1.670 | 1.697 |
| partial | 0.861 | 2.362 | 2.533 |
| phrase construction | 9.290 | 24.494 | 24.733 |
| mixed | 3.255 | 10.484 | 10.583 |
| long ambiguous composition | 11.922 | 165.244 | 167.211 |
| literal fallback beyond decoder limit | 0.009 | 0.009 | 0.011 |
| personal phrase prefix at full capacity | 1.999 | 10.705 | 11.105 |
| dense known composition | 7.130 | 21.603 | 22.910 |
| dense prefix with unknown tail | 8.626 | 112.417 | 118.509 |
| bounded long personal expansions | 11.368 | 30.577 | 30.892 |
| learned tokens in longer composition | 16.665 | 81.887 | 82.796 |
| bounded Unicode personal expansions | 32.464 | 103.673 | 114.476 |

The index-only change preserved all thirteen original candidate fingerprints before importing data. For the expanded vocabulary, incremental terminal selection preserved all thirteen fingerprints relative to full terminal sorting, while reducing that run's maximum resident set size from 579,452,928 to 225,181,696 bytes (552.61 to 214.75 MiB). Final peak memory footprint was 218,219,144 bytes, with 121.41 seconds elapsed for the measured CLI. These are process-level synthetic measurements, not app memory, cold-start measurements or native key-to-screen latency. The larger vocabulary costs substantially more than the original seed; the long ambiguous case still takes about 165 ms median, and the full-capacity prefix case returns 9,154 candidates. Broader data import and native responsiveness remain unvalidated.

No input method was installed, input sources changed, user phrases/learning archives read, or native host apps operated for this change. Host typing, focus/shortcuts, broad-prefix paging, startup, VoiceOver and appearance require the relevant [manual checks](TESTING.md) before release. No commit or push was performed.

## English vocabulary maintenance — 2026-10-19

This checkpoint adds a maintained English vocabulary; the earlier registration, candidate-window and performance checkpoints below remain historical evidence.

English now merges 61,172 filtered ESDB/SCOWL word forms, 638 original SI entries and 22 SI terminology/coverage additions into 61,216 unique lookup spellings. The source revision, full copyright notice, selection settings and SHA-256 values are checked in. `subtitle`/`subtitles`, case handling, language filtering, full prefix results and mixed input have focused regression coverage. Imported letter-name entries are filtered so arbitrary input does not become a sequence of supposedly known English letters. Existing SI completion preferences retain their score in the larger mixed search.

Validation on Apple Silicon macOS 27.0.1, Xcode 27.1, Swift 6.4:

- `./scripts/test.sh`: all 142 tests passed (112 core, 12 storage, 18 settings).
- `python3 -m unittest discover -s Tests/VocabularyTests -v`: all 14 maintenance tests passed, covering merges, persistent corrections/exclusions, rejected data, provenance/checksums, first imports, failure preservation, snapshot repair, safe archive extraction and audit rate-limit fallback.
- `./scripts/vocabulary.sh build --check`: generated data, merged provenance table, summary and notices match their source inputs.
- A real `refresh scowl` reproduced the pinned import and all generated fingerprints exactly. A real upstream `audit` confirmed that the pin matched branch `v2`; the first API request hit a shared rate limit, and public Git ref discovery succeeded after adding and testing that fallback.
- Debug and Release builds succeeded. Both bundles contain the exact generated `EnglishVocabularyNotices.txt`. The only build warning was the existing skipped AppIntents metadata extraction without an AppIntents dependency.
- Workflow YAML, shell syntax, local documentation links and whitespace checks passed. The monthly workflow was validated locally, not run on GitHub; scheduling requires merging it to the default branch with Actions enabled.

The final standalone Release benchmark ran at 2026-10-19T07:04:11Z with the existing thirteen synthetic scenarios, 5,000 aggregate preferences, 1,000 personal phrases, 10 warmups and 200 measured iterations per scenario. The before run used the earlier 638-word English vocabulary in this session; the after run used the maintained vocabulary. The larger candidate set increases costs in several cases; these measurements do not claim a latency improvement.

| Scenario | Before median (ms) | After median (ms) | After p95 (ms) |
| --- | ---: | ---: | ---: |
| short | 0.092 | 0.197 | 0.201 |
| ambiguous | 0.057 | 0.262 | 0.268 |
| partial | 0.107 | 0.799 | 0.808 |
| phrase construction | 1.236 | 8.525 | 8.561 |
| mixed | 0.455 | 2.996 | 3.017 |
| long ambiguous composition | 5.543 | 10.794 | 10.841 |
| literal fallback beyond decoder limit | 0.014 | 0.008 | 0.009 |
| personal phrase prefix at full capacity | 0.687 | 1.962 | 1.989 |
| dense known composition | 5.768 | 6.472 | 6.504 |
| dense prefix with unknown tail | 5.979 | 7.854 | 8.003 |
| bounded long personal expansions | 10.270 | 10.888 | 10.973 |
| learned tokens in longer composition | 3.101 | 14.395 | 14.475 |
| bounded Unicode personal expansions | 28.866 | 30.892 | 31.061 |

The expanded-vocabulary CLI reported 50,446,336 bytes maximum resident set size (48.11 MiB), 45,089,296 bytes peak memory footprint, and 21.07 seconds elapsed. These are process-level synthetic measurements, not native key-to-screen latency or app memory. The full-capacity prefix case returns 4,611 candidates; broad-prefix native paging and responsiveness require manual checks. Output fingerprints can change because vocabulary and segmentation changed.

No input method was installed, no input source was changed, and no user phrases or learning records were read. Real-host typing, focus/shortcuts, native candidate paging, VoiceOver and appearance remain unverified for this expanded vocabulary. Follow [the vocabulary workflow](ENGLISH_VOCABULARY.md) and [manual checks](TESTING.md) before release.

## Registration repair — 2026-10-19

The user reported that SI was still absent after installation and logout. The installed app existed in `~/Library/Input Methods/SI.app` and passed strict code-signature verification, but a bundle-filtered Text Input Services query in the login session returned zero sources for `com.caterm.si`.

The bundle/source identifier now includes the InputMethodKit discovery segment (`com.caterm.inputmethod.si`), and the app declares `LSBackgroundOnly`. Settings uses accessory activation when shown. The installer accepts and backs up the earlier bundle, explicitly registers SI, and checks for exactly one selectable keyboard input method without enabling/selecting it. Language, punctuation, and learning-consent settings keep the original `com.caterm.si` domain; archive paths are unchanged.

Debug and Release app builds succeeded. The registration helper passed Swift type checking; shell/plist syntax and whitespace checks passed. The corrected app was installed with the supported installer, preserving a backup. The helper's initial directory-URL comparison incorrectly rejected the installed path; after correcting that comparison, registering the already installed bundle reported `Verified: one selectable SI keyboard input source (com.caterm.inputmethod.si)`.

Automated tests remain paused at the user's request. No input source was enabled or selected, no process was killed, and no logout was initiated. Settings visibility, the system input-source picker, typing, and preference retention across the upgrade still need manual verification. The automated/performance evidence below describes the earlier checkpoint and was not rerun for this registration repair.

The user then requested classification under English. `TISIntendedLanguage` changed from `zh-Hans` to `en`, retaining both character repertoires, the source identifier, enabled-language behavior, and preference/archive locations. The guarded installer completed a Debug build, signing, backup, installation, and registration. Text Input Services confirmed one selectable SI keyboard input source with English first in its language list; the helper reported `Primary discovery language: en (English)`. Helper type checking, plist/shell syntax, and whitespace checks passed. No automated tests or Release build were rerun for this metadata-only follow-up; the input-source picker's appearance remains a user verification step.

## Candidate keys and icon follow-up — 2026-10-19

The user confirmed SI can now be added, then reported a high-positioned icon and ineffective number/arrow keys. The icon changed from a single 32-point bitmap to glyph-centered 16-point 1x/2x TIFF representations. Bitmap inspection found 16×16 and 32×32 pixels, both carrying 16×16 point size; the alpha bounds are centered to within one pixel.

The controller now consumes Up/Down, page navigation, and number-selection events explicitly, using public native candidate-identifier APIs checked against the installed SDK. Number selection resolves the window's visible line, retaining correct mapping after scrolling. Selection uses the same commit/learning validation as native callbacks. Left/Right continues to edit composition; Return preserves spelling and shortcuts pass through.

The icon generator ran and the Debug app build succeeded. Whitespace checks passed. Automated tests remain paused at the user's request. Installation was attempted through the supported installer and stopped at its running-process guard: the installed SI is still the previous version. No process was terminated, no source was changed, and no logout was initiated. Runtime key routing, the picker's visual alignment, and host compatibility remain unverified for this follow-up.

## System input-source secondary label — 2026-10-19

The user supplied a screenshot of macOS's input-source list displaying SI with a second, smaller “SI” line and requested a single-line name. SI has no view for this system-owned row and declares no input modes or custom subtitle. Inspection of its bundle metadata, public Text Input Services declarations, and Apple's bundle-name documentation did not establish a supported way to suppress only the secondary label. This remains unresolved; no name, identifier, or registration fields were changed speculatively. The investigation made documentation-only changes, without builds, tests, installation, or system-setting changes.

## Owned candidate panel and directed regressions — 2026-10-19

The user reported that the updated native candidate window still lacked numbers and did not respond to digits or Up/Down. The earlier native identifier-based implementation therefore remains a failed runtime attempt, despite compiling. SI now uses its own nonactivating AppKit candidate panel and one client-local selection/page model. The numbered rows, highlight, digit lookup, mouse actions, page controls, scrolling, and Space confirmation read that same state; no `IMKCandidates` instance is created. The existing engine, session, learning/storage policies, and exact-text commits remain shared.

The user explicitly allowed directed regression checks to resume. `./scripts/test.sh --filter 'CandidateSelectionTests|CandidateViewTests|PartialCommitTests|CompositionEditingTests|CompositionBoundaryTests'` passed 28 tests: 11 presentation checks and 17 related composition/prefix/boundary checks. These include real `NSEvent` values passed through the same action mapping used by the controller, visible number labels, highlight/page alignment, final-page bounds, mouse actions, language/literal identity, selection reset, whole/prefix commits, and learning eligibility. The AppKit checks render synthetic views offscreen without showing windows or operating another application. The retained `.build/candidate-panel-preview.png` was visually inspected for 1–9 labels and the selected row; label padding was corrected after inspection. These checks do not establish actual host event delivery.

The Debug app build succeeded, with only the existing AppIntents metadata-extraction warning. Full-suite tests, benchmarks, Release compilation, live VoiceOver/appearance checks, host key routing, caret positioning and focus transitions were not rerun/verified in this follow-up. Installation through the supported script stopped at the running-process guard. The currently running installed SI was not replaced or terminated; no input source or login-session setting was changed. A manual update and host verification are still required before claiming the reported runtime problem is resolved.

## Candidate-window visual refinement — 2026-10-19

At the user's request, ordinary visible language descriptions (including “Chinese + English”) were removed from candidate rows. Language identity, full tooltip/accessibility descriptions, sorting, and commit text remain unchanged. Compact hints retain prefix/personal/original/verbatim distinctions. The panel now uses a compact 180–600 point card, 30-point rows, system colors, subtle numbering and borders, and a small page count with accessible chevrons. One-page results omit the footer.

The same directed test filter passed 30 tests: 13 presentation checks and 17 composition/prefix/boundary checks. Added coverage verifies hidden visual language metadata with retained accessibility/identity, concise prefix/original hints, compact single-page layout, conditional pagination, and accessible next-page actions. The Debug app build passed, with the existing AppIntents metadata warning. Synthetic light, dark, and three-row previews at `.build/candidate-panel-refined.png`, `.build/candidate-panel-refined.dark.png`, and `.build/candidate-panel-refined.compact.png` were rendered offscreen and visually inspected.

No installation, process termination, source change, or host-app operation was performed for this styling request. These checks do not establish live host routing, actual VoiceOver behavior, screen-edge placement, or automatic appearance switching. The full test suite and Release build were not rerun; regression work remains scoped to the previously authorized candidate checks.

## Input-source badge background — 2026-10-19

At the user's request, SI's bare lettering gained a rounded charcoal background and white glyphs, plus an inverse light badge for selected rows. The generator remains original AppKit/Core Text code. `TISIconIsTemplate` is false and the alternate asset is declared through the installed SDK's `tsInputMethodAlternateIconFileKey`; identifiers and language registration are unchanged.

The generator ran successfully. Bitmap inspection confirmed 16×16 and 32×32 representations with 16×16 point logical size and both foreground/background colors in each of the two assets. A synthetic normal/selected menu preview at `.build/icon-badge-preview.png` was visually inspected. Debug compilation passed, and both assets plus the expected template/alternate metadata were checked in the built app. Plist syntax and whitespace checks passed. No tests, installation, process termination, input-source change, or live system-menu verification was performed for this asset change.

## Candidate positioning and mixed-word investigation — 2026-10-19

The user reported a candidate panel displaced from the marked composition. The controller now queries the composition's first UTF-16 position before the current caret. Geometry is validated against connected displays, cached only within that client/composition, and cleared on commit, cancellation, and deactivation. Missing geometry no longer invents a screen-center anchor. Placement uses AppKit screen points directly and clamps below/above the anchor within that screen's visible frame.

The directed filter covering selection, views, placement, partial commits, editing, boundaries, and `MixedWordBoundaryTests` passed 38 tests across the presentation and core test products. Six placement checks cover query order, zero-width caret rectangles, temporary failures, cache reset/isolation, invalid coordinates, screen edges, left/above display layouts, and display removal. Two mixed-word checks (including three parameterized examples) establish that intact English `title` precedes `tit了` in synthetic compositions with learning off. The Debug app build passed, with the existing AppIntents metadata warning. Whitespace checks passed. No installation or host-app operation was performed; actual browser coordinate delivery, live display changes, focus behavior, and VoiceOver remain unverified. Full-suite/Release/benchmark checks were not resumed beyond the user's directed regression scope.

A temporary synthetic learning diagnostic reproduced the reported mixed-word ranking reversal: for `nibuxiangyaotitle`, the intact candidate's base score is 90.4 versus 89.2 for the split candidate. A single-language `le` → `了` preference with strength 1 adds approximately 1.412 token points to the split path, making it first. No personal archive or host text was read. This establishes a possible mechanism, not the user's actual retained preference or installed-build state. The decoder still lacks a word-boundary safeguard against this token-learning effect; no speculative ranking change has been made. Confirmation of the user's learning setting is pending. The temporary printing diagnostic was removed; baseline regression fixtures remain.

## Mixed English word boundary learning safeguard — 2026-10-19

The user could not confirm whether learning was enabled when the ranking issue occurred. The repair therefore targets the demonstrated synthetic failure without reading or clearing any private profile; the original screenshot's precise runtime cause remains unconfirmed.

`PinyinDecoder` now suppresses token bonuses for a constructed path that continues with another token inside a longer exact lexical English word. The boundary metadata stays query-local and shares the existing continuation beam budgets. Exact word endpoints come from existing edges and respect explicit separators; tracking is inactive without positive matching token bonuses. Personal/verbatim paths keep their existing exclusions. Base costs, direct lookup, whole/prefix preferences, language filtering, literal fallback, and retained learning data are unchanged. Whole-candidate and previous-word preferences can still favor an explicitly chosen alternative segmentation.

The failing regression was demonstrated before the fix. Stronger first-choice assertions then exposed the same problem through an English completion (`tit` + `learn`), so the safeguard covers both Chinese and English continuation tokens. Seven `MixedWordBoundaryTests` methods cover six combinations of learning strength/English preference, four additional word/casing/continuation examples, ordinary Chinese endings and explicit boundaries, deliberate whole/prefix preferences, and the baseline examples. With learning off or injected single-word preferences, the tested intact words precede split alternatives; with combined preferences, `你好title` is first in the corresponding regression cases. The split `你好tit了` candidate and exact literal remain available.

The final directed test run passed 138 tests: 119 core candidate/decoder/learning/session checks and 19 presentation checks. It includes the bounded-search/Unicode, terminal/prefix, enabled-language, personal/verbatim, context, editing, and candidate-placement regressions. The final Debug build passed, with only the existing AppIntents metadata warning. Whitespace checks passed. Full-suite storage/settings checks, Release compilation, benchmarks, live host routing, positioning, and VoiceOver were not run for this repair. No installation, process termination, input-source change, or host-app operation was performed. These fixes still require an installed update and relevant manual host checks; the lexical safeguard does not establish general semantic ranking quality.

## Environment and automated evidence

- Apple Silicon macOS 27.0.1, Xcode 27.1 (27A9275), Swift 6.4 in Swift 6 language mode.
- `./scripts/test.sh`: 128 Swift Testing tests passed: 98 core tests, 12 storage tests, 18 observable-settings tests. The final test build reported no warnings. Fixtures use synthetic data and isolated temporary files/defaults domains.
- `./scripts/build.sh`: the latest comparison/hash optimization built successfully in the Debug app target.
- `./scripts/build.sh Release`: latest app source built successfully for configured arm64 and x86_64 architectures. The build emitted only the AppIntents metadata-extraction warning because SI does not depend on AppIntents. This is compilation evidence, not Intel runtime or macOS 14 compatibility evidence.
- `git diff --check`, Markdown/local-link checks, and shell syntax checks passed at this checkpoint.
- At the earlier checkpoint, no input-source installation/activation, logout, process termination, signing-identity change, or third-party dictionary import was performed. The later registration repair above installed and registered SI without activating it. Independent website changes in the shared checkout were preserved.

Core coverage includes ambiguity, literal retention, provider-output validation, phonetic boundaries/full-initial combinations, incomplete mixed endings, verbatim-span privacy, constructed/mixed/personal-node phrases, bounded long outputs, explicit language identity, fractional ranking and language-transition costs, prefix confirmation with exact source offsets/remainders, punctuation policy/safeguards, effective-score deduplication, caret editing, whole-character deletion, separately inserted scalars joining into graphemes, UTF-16 offsets, stale selections, bounded/decaying preferences, context isolation/expiry/reset, and phrase validation/capacity/atomic merge. Ten synthetic everyday sentences absent as whole lexical entries rank first; this is a small authored regression suite, not independent quality evaluation.

Token-ranking coverage verifies that a standalone preference changes longer compositions before pruning, preserves ordinary alternatives through a base beam, handles English final completions and phonetic aliases/boundaries, normalizes repeated-token influence, and shares the frequency cap with whole-input preferences. Tests exercise effective-score deduplication across direct/constructed derivations, canonical Unicode equivalence, restart, pause, injected secure input, deletion, clear, expiry/prune, context/mixed-record isolation, personal/verbatim exclusion, and prefix-only weighting. Confirming compositions creates no inferred component-word records.

Search-optimization checks compare the best bounded results against 6,561 exhaustively generated small-vocabulary paths in different insertion orders, including canonical equivalents, compatibility ideographs, and emoji. Additional fixtures verify that equivalents across the byte-comparison/Unicode paths do not consume duplicate beam slots and that cross-token accent/Hangul composition never rewrites committed UTF-8 bytes.

Storage/model coverage includes restart, corruption/unsupported/oversized archives, bounded reads, file permissions, revision ordering, write failure/retry, additive import/export, failed-import error persistence, learning schema-1 migration to schema 2, opt-in/pause, consent/clear invalidating session context, preview isolation, and injected secure-event suppression. Tests of these models do not prove macOS delivers the expected focus/key callbacks.

## Synthetic performance

`./scripts/benchmark.sh --resources > .build/search-final-benchmark.json 2> .build/search-final-resources.log` ran in Release mode with 5,000 aggregate preferences and 1,000 personal phrases, 10 warmups and 200 measured iterations per scenario. The latest report timestamp is 2026-10-18T11:52:17Z, collected after the app build finished. Long ASCII expansions use 20 phrases of 1,001–1,002 bytes; the Unicode/emoji case uses 20 phrases of 841–842 bytes. Each dictionary also contains 980 short phrases; the other cases use 1,000 short phrases. The learned-token case replaces one synthetic preference with a relevant `shi` → `时` record, keeping capacity at 5,000. JSON includes maximum phrase size and synthetic output fingerprints.

| Scenario | Letters | Median (ms) | p95 (ms) |
| --- | --- | --- | --- |
| short | 3 | 0.088 | 0.100 |
| ambiguous | 2 | 0.062 | 0.062 |
| partial | 4 | 0.116 | 0.121 |
| phrase construction | 18 | 1.225 | 1.240 |
| mixed | 16 | 0.480 | 0.487 |
| long ambiguous composition | 60 | 5.454 | 5.761 |
| literal fallback beyond decoder limit | 128 | 0.013 | 0.014 |
| personal phrase prefix at full capacity | 1 | 0.716 | 0.733 |
| dense known composition | 64 | 5.981 | 6.069 |
| dense prefix with unknown tail | 64 | 6.118 | 6.259 |
| bounded long personal expansions | 20 | 10.443 | 11.095 |
| learned tokens in longer composition | 17 | 3.115 | 3.176 |
| bounded Unicode personal expansions | 20 | 29.230 | 30.727 |

The full-capacity prefix scenario returns 1,078 candidates. Sampling only the self-launched synthetic benchmark located repeated long-prefix sorting and Unicode hashing costs. Guarded byte comparison/canonical hashing lowered the long ASCII expansion p95 from 27.584 ms in the before-change run (2026-10-18T11:28:19Z) to 11.095 ms, approximately 60%. All twelve existing scenarios retained matching fingerprints of synthetic output order and public scoring/flags. The added Unicode scenario has no pre-optimization baseline; its 30.727 ms p95 remains an explicit optimization priority. Fingerprints and small exhaustive fixtures provide regression evidence, not proof over all inputs.

`time -l` reported 31,621,120 bytes maximum resident set size (30.16 MiB), 25,281,064 bytes peak memory footprint (24.11 MiB), and 13.47 seconds elapsed across the thirteen-case benchmark executable. The additional Unicode dictionary/workload makes memory totals different in scope from the previous twelve-case run. These cover the synthetic CLI process only. Engine timings exclude InputMethodKit callbacks, UI rendering, IPC, storage, and host-app latency/memory; they do not establish production-lexicon performance or acceptable native responsiveness.

## Missing evidence and remaining capabilities

- SI Settings and actual typing were not inspected. Under the user's SI-only authorization, the latest targeted read timed out; a follow-up returned a connection-availability notice without app state. Earlier targeted reads were also unavailable. No other apps were inspected and no alternate control backend was used.
- Native candidate paging/selection, actor callback threading, marked-text caret editing, focus/shortcut routing, context resets in real clients, secure fields, native import/export dialogs, displays, VoiceOver, and dark mode still require the checks in `docs/TESTING.md`.
- Original vocabulary coverage remains insufficient for broad daily use. Fuzzy decoding, broader unknown-word detection, internal pair/sentence ranking, and independent input-quality evaluation remain pending. Word frequency now influences internal tokens, while previous-word pairs still rerank generated whole/prefix candidates after search.
- Prefix remainder handling, configurable punctuation/Tab, and personal nodes have core regression coverage, but their native callbacks and UI remain unverified. Punctuation outside composition passes unchanged; quotes are not automatically paired.
- Signed/notarized distribution, installer runtime recovery, other macOS versions, and host compatibility remain unverified.

See `docs/IMPLEMENTATION_PLAN.md` for the preserved objective and remaining work. These automated results do not establish that the full objective is complete.
