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
