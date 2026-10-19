# Implementation verification — 2026-10-18

This records the current implementation checkpoint, not a stable-release certification. The overall daily-use input-method objective remains open.

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
