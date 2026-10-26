# Implementation verification — 2026-10-18

This records the current implementation checkpoint, not a stable-release certification. The overall daily-use input-method objective remains open.

## First-row column alignment — 2026-10-26

Expanded candidate rows now reuse the first row's six column origins and widths. Numbers and text align vertically in both appearances and at narrow widths; short candidate content/source icons and selection backgrounds still fit their text within the shared column. Numbered selection, mouse identities, page state and candidate generation are unchanged.

All 353 Swift tests and the Debug build passed. The focused 18 view tests include first-row/compact equivalence, shared column widths and number/text insets, mouse identities and 340-point bounds. Light/dark regular and narrow renders were inspected. No input method was installed; live host/VoiceOver checks remain unverified. Evidence: `/tmp/si-grid-aligned-tests.log`, `/tmp/si-grid-aligned-focused.log`, `/tmp/si-grid-aligned-build.log` and `/tmp/si-grid-aligned.*.png`.

## Down Arrow and four six-choice rows — 2026-10-26

Down Arrow now expands a collapsed candidate strip without advancing selection. Both layouts use six-choice keyboard pages. The expanded panel displays up to four pages as rows (24 candidates), with the original compact style on the first row. Each row repeats digits 1–6; the active row is emphasized, digit selection targets that row, and every displayed candidate remains clickable by identity. Page keys and expanded Left/Right move six choices; the fifth page changes the displayed block and retains access to all 27 shortlist entries. Expansion/collapse preserves the active candidate/page/digit, and empty composition resets expansion. Expanding suspends automatic confirmation through the same controller path as the chevron.

Narrow rows reserve a minimum number/glyph budget before distributing extra width. Tight cells reduce padding and hide source icons while retaining complete tooltips/accessibility. Natural widths do not depend on that temporary icon visibility. The panel measures against the anchor screen before placement. Full candidate generation, scores, privacy/storage and host focus ownership are unchanged.

All 353 Swift tests passed (259 core, 74 presentation, 14 settings, 3 storage and 3 localization), including real-key expansion, four-page viewport transitions, repeated numbering/active-row/mouse identities, exact word-by-word title commits, pending controls and narrow-screen geometry. Debug build passed. Light/dark regular and 340-point grid renders were inspected. No input method was installed, and native host event routing/VoiceOver remain unverified. Evidence: `/tmp/si-grid-six-tests.log`, `/tmp/si-grid-six-build.log`, `/tmp/si-grid-six-focused.log` and `/tmp/si-grid-six.*.png`.

## Four leading hypotheses and a word-only tail — 2026-10-26

At the user's request, sentence-led window lists now show up to four sentence/fragment hypotheses followed by single-character/word candidates. Extra constructed sentences and multiword fragments no longer occupy later pages. Required language/mixed hypotheses share the four slots. Word-led queries keep engine-relative order; explicit personal phrases, punctuation choices, separate App History placement and the final exact literal remain available. This supersedes the earlier three-reading grouping and tail-reading protection described below. Engine results, scores, bounded search and automatic-confirmation evidence are unchanged.

`sheguofennudehai` previously lost `涉` from the bilingual 27-item shortlist. Provisional/full and separated-spelling regressions now check the four-hypothesis head and word-only tail, exact consumed spelling, both panel layouts, and the full `涉` → `过` → `愤怒` → `的` → `海` sequence. The old `二倍做多` fixture remains available in full engine results; its appearance in the four-hypothesis window is no longer guaranteed. Presentation fixtures now declare their lexical metadata rather than treating every synthetic row as an unknown constructed candidate.

All 350 Swift tests passed (259 core, 71 presentation, 14 settings, 3 storage and 3 localization), followed by the focused title/prefix/alternative checks; the Debug app built successfully. Light/dark compact/expanded first-page renders were inspected. No input method was installed, and native host/VoiceOver behavior remains unverified. Evidence: `/tmp/si-four-tests.log`, `/tmp/si-four-focused.log`, `/tmp/si-four-build.log` and `/tmp/si-four-title.*.png`.

## Requested removal of failing tests — 2026-10-24

At the user's request, ten failing test functions were deleted from eight core test files. The baseline ran 352 Swift tests; ten core tests produced 23 issues. Removed checks covered abbreviation/full-spelling retention, personalized search and terminal compaction, mixed token learning, trailing spelling separators, normalized aliases, prefix ranking and standard-vocabulary automatic confirmation. Product implementation is unchanged, so passing the reduced suite does not establish that these behaviors were fixed.

- `./scripts/test.sh` passes all 342 remaining tests: 258 core, 67 presentation, 14 settings and 3 storage.
- `./scripts/build.sh` passes for the Debug app with signing disabled. No Release build or native-host verification was performed for this deletion.
- No input method was installed or launched, and no input sources or private archives were changed.

Evidence: `/tmp/si-test-20261024.log` (baseline), `/tmp/si-tests-after-removal-20261024.log` and `/tmp/si-build-after-test-removal-20261024.log`.

## Default-off punctuation candidate setting — 2026-10-24

Settings → Typing now includes Show punctuation candidates, off by default and persisted independently of languages and the composition punctuation policy. With it off, punctuation outside composition passes through and neither engine generation stage nor Settings preview creates punctuation variants. Enabled punctuation retains E/C/A badges and acceptance without an extra space. Explicit candidate metadata controls this presentation and acceptance behavior; ordinary literal handling remains available when the option is off.

- All four new regressions pass: default-off full/provisional generation, persistence and configuration revision changes, stale session results/selections across a toggle, and Settings preview replacement. The focused selection passes 45 tests. Existing AppKit coverage now explicitly enables the feature and verifies disabling it removes the badge presentation in both layouts.
- `./scripts/test.sh` runs 352 tests versus the isolated unmodified baseline's 348. Settings/storage and all 67 presentation tests pass; Core reports the same 23 issues. Recorded failing test names, source locations and occurrence counts exactly match the baseline; the existing decoding/search/automatic-confirmation failures remain unresolved.
- `./scripts/build.sh` succeeds for the Debug app with signing disabled. The existing AppIntents metadata warning remains. Builds/tests required normal compiler/cache access outside the restricted nested sandbox. Whitespace and local documentation-link checks pass.

No app was installed or launched, and actual user preferences, enabled input sources and private archives were not changed. Native Settings keyboard/VoiceOver interaction and host key routing remain unverified; manual switch/preview/persistence steps are in [testing](TESTING.md#language-labeled-punctuation-candidates). Local evidence: `/tmp/si-punctuation-setting-focused.log`, `/tmp/si-punctuation-setting-tests.log`, `/tmp/si-punctuation-setting-build.log`, `/tmp/si-punctuation-setting-baseline-tests.log` and `/tmp/si-punctuation-setting-comparison.json`.

## Chinese sentence alternatives and six-choice compact pages — 2026-10-24

The MSIME source review previously confused low-level lattice defaults with the host's actual options. The retained host enables `sentence_alternatives` unconditionally; its runner-up ordering keeps three same-length generated readings for outputs of at least three characters, one for two-character outputs, and moves other readings back rather than deleting them. `MSIME_ALGORITHM.md` now links both implementations and corrects the earlier product claim.

SI now emits all six distinct rescored terminal readings per base/personalized lane, with at most twelve distinct ordinary Chinese generated readings after lane merging. Explicit transient provenance distinguishes these from direct lexical, English, mixed, personal, punctuation and history candidates. A direct lexical duplicate retains lexical placement. `CandidateShortlist` protects the bounded generated readings, groups the first three long readings (one for two-character readings), then moves the remainder behind ordinary choices. History is placed after the first two whole choices and exact literal input stays last. The window keeps its 27-choice cap. Engine/Settings results retain score order and full emitted alternatives. The separately requested compact page size is six; expanded pages remain nine.

- `./scripts/test.sh` runs 348 tests: Settings (3), Storage (12) and Presentation (67) pass; Core (266) reports 23 issues across ten failing tests. Every remaining failure signature was present in the pre-change 51-issue baseline. The reduction includes corrected stale normalized-score/12-result test expectations and broader sentence recall; it is not an independent quality improvement measurement. Existing failures in abbreviations, incomplete/mixed boundaries, terminal compaction and automatic confirmation remain active.
- All eight added tests pass: seven core checks plus one AppKit test covering provisional/full and both layouts. Added and updated regressions verify bounded six-result output, independent exhaustive costs, base/personalized retention, lexical deduplication, long/short sentence placement, tail reachability, pins/history/languages/literal preservation, and exact reported-text commits. A consumed-prefix cost check now permits floating-point roundoff from projecting retained whole paths.
- `./scripts/build.sh` passes for the Debug app with signing disabled and the existing AppIntents metadata warning. Final focused checks pass 18 tests across core/presentation. Compiler runs required normal SwiftPM/Xcode cache access outside the restricted sandbox. Whitespace and touched-document local links pass.
- Actual offscreen bilingual pages containing `二倍做多` were inspected in compact/light and expanded/dark renders, with light/dark variants generated for both layouts. The candidate is retained on a later page and digit/mouse/highlight mapping agrees. `而被做多` remains the leading full reading under the current scores; first-choice parity with the user's MSIME screenshot is not established.

Evidence: `/tmp/si-six-candidates-final-tests.log` (baseline), `/tmp/si-sentence-alternatives-final-tests.log`, `/tmp/si-sentence-alternatives-final-focused.log`, `/tmp/si-sentence-alternatives-build.log`, and `/tmp/si-sentence-alternative.{compact,expanded}.{light,dark}.png`. No installation, app launch, process termination, input-source change or private archive access was performed. Native host typing, focus/shortcut behavior, candidate positioning and VoiceOver remain unverified; see [manual checks](TESTING.md#four-leading-hypotheses-and-word-selection).

## Complete-input continuation comparison — 2026-10-23

This supersedes the raw whole/prefix comparison below. Prefix lexical scores remain unchanged, but their comparison now accounts for the rest of the current input. Exact source/UTF-8 alignments project compatible full hypotheses onto prefix actions; other prefixes use retained suffix paths and bounded short bridges with corrected word/language context. An additional confirmation has an explicit one-bit binary action prior. Long unsupported gaps pay an unknown-span cost. The window keeps engine order without prefix promotion or whole-choice quotas, and frequency resources are unchanged.

- `iwanttobuild` now leads with `I want to build`: its unchanged base/comparison score is -19.350492; the strongest prefix comparison score is -20.350492. `nihaopengyou`, `biruzhege`, `danci` and `zhegeshurufakeyishuruzhongwenheyingwen` retain their complete default choices through single-language/bilingual, provisional/full and compact/expanded cases. `显示` and `现实` remain on the first `xianshi` page. Explicit prefix confirmation still consumes the exact source span and leaves its remainder editable.
- The corrected quality tool uses the same ordered `CandidateShortlist` as the window and includes prefixes. On 86 fixed known fixtures, actual first-choice hits improve from 3 to 64 and actual top-five coverage from 32 to 83; provisional top-five coverage also improves from 32 to 83. Engine recall stays 83/86 and provisional/full first-choice agreement stays 86/86. Character error rate changes from 0.761221 to 0.070018 on this set. The old whole-only metric hid the short-prefix regression. These inspected development/historical fixtures are not an independent accuracy estimate.
- Whole-only first-choice hits remain 65/86. The remaining prefix/whole discrepancy is `srf`: `虽然` precedes the complete `输入法` abbreviation. Positive action-cost sensitivity at 0.5, 1 and 2 bits gives 64 actual first choices; 4 bits gives 65. The uniform one-bit prior is retained rather than tuning a larger penalty to that known abbreviation. Initial ambiguity, missing candidates and other documented decoder limitations remain.
- `./scripts/test.sh` runs 340 tests: Settings (3), Storage (12) and Presentation (66) pass; Core (259) reports the same 51 issues, failing test names and per-test issue counts as the pre-regression core baseline. No new full-suite failure is observed. The committed raw-score regression had 141 core issues. Nine new core tests cover full-input comparison, exact byte/source alignment, Han/umlaut separators, bridge grouping, unknown tails, own-frequency preservation and prefix-only learning. The added presentation test types continuous input character by character and confirms the complete default exactly once. Existing automatic-confirmation checks now also verify unchanged full-input scores.
- `./scripts/build.sh` passes for the Debug app, signing disabled, on both application architectures. The Release benchmark compiles the same core. Compiler checks required normal Xcode/SwiftPM cache access outside the restricted sandbox. Whitespace and local documentation file-link checks pass.

The final synthetic Release benchmark runs twenty-five scenarios with 10 warmups and 200 samples each, plus the existing twenty-sample edit comparisons, on arm64/macOS 27.0.1 (26A434). Median/p95 milliseconds include:

| Scenario | Median | p95 |
| --- | ---: | ---: |
| Continuous `iwanttobuild` | 2.546 | 2.642 |
| `xianshi` homophones | 5.938 | 6.066 |
| `biruzhege` | 8.691 | 8.896 |
| Constructed Chinese phrase | 19.269 | 19.929 |
| Sixty-letter ambiguous cuts | 156.678 | 160.301 |
| Chinese-only unknown ending | 61.164 | 61.665 |
| Deferred edit burst | 0.012 | 0.015 |

The maximum among the measured search scenarios is 161.897 ms. These are in-process synthetic measurements, not native-host latency guarantees. Scoring costs more CPU than the raw-score baseline: its reference medians were 8.634 ms for the constructed phrase, 106.974 ms for ambiguous cuts and 26.688 ms for synchronous edits, versus 19.269, 156.678 and 51.760 ms now. Deferred edits remain separate from background generation. No general speedup is claimed. Reusing source traces and cached short bridges avoids the second-scale long-input amplification observed in the discarded per-suffix full-decode prototype.

No input-method app was installed or launched. Enabled input sources, existing input-method processes and private archives were unchanged. Native host typing, focus/shortcut routing, VoiceOver and positioning remain unverified. Manual steps are in [testing](TESTING.md#full-input-prefix-scoring). Evidence: `/tmp/si-completion-quality-before.json`, `/tmp/si-completion-quality-final.json`, `/tmp/si-completion-timing-before.json`, `/tmp/si-completion-timing-final.json`, `/tmp/si-completion-final-all-tests.log` and `/tmp/si-completion-final-build.log`.

## Score-only whole/prefix ordering — 2026-10-23

This supersedes the single-word first-page policy below. The user rejected both forced prefix promotion and a five-whole-choice fallback. `CandidateEngine` now orders ordinary whole and prefix candidates together by effective score, removing whole-first and longest-consumed-span precedence. `CandidateSelection` only retains a bounded ordered subsequence and pages it; lexical-unit count, word/character type and sentence status no longer move or hide results. Explicit personal pins, separate history placement, exact literals and language-aware shortlist retention preserve their existing contracts. Dictionary frequencies and scoring formulas are unchanged.

With empty learning in both Chinese-only and bilingual provisional/full searches, `biruzhege` gives `比如` -3.414 and `比如这个` -8.546, so the prefix naturally leads without promotion. `xianshi` retains `显示` at position 3 (-10.819) and `现实` at position 4 (-11.157). The existing scores also favor shorter prefixes for other inputs: `danci` gives `但` -5.144 and `单词` -9.960; `iwanttobuild` gives `I` -3.192 and `I want to build` -19.350. These are observed ranking limitations, not a vocabulary-quality improvement. No unsubstantiated frequency overrides were added.

- The final focused run passes all 44 tests: 26 presentation tests and 18 engine/prefix-commit tests. Coverage includes fractional score ordering across source spans, deterministic input-order independence, consumed-spelling learning, an isolated dictionary-frequency increase that naturally moves a prefix above a whole phrase, exact numbered commits, source remainders, both search stages/layouts, history placement and ordered 27-choice shortlisting. Light/dark offscreen sentence-page rendering and click identity also pass.
- `./scripts/test.sh` runs 330 tests: Settings (3), Storage (12) and Presentation (65) pass; Core (250) reports 141 issues. The pre-change baseline had 12 presentation and 51 core issues. Core first-choice/quality assertions remain active: the additional failures expose the changed score competition with shorter prefixes, including Chinese word/sentence and continuous English cases. This is not a passing full regression suite. No broad quality assertions were weakened to conceal these results.
- `./scripts/build.sh` passes for the final Debug app with signing disabled. Compiler checks required normal Xcode/SwiftPM cache access outside the restricted sandbox. No installation, app launch, input-source change or private-data inspection was performed. Native host input, keyboard/mouse routing, focus/shortcuts, VoiceOver and candidate positioning remain unverified.

Evidence: `/tmp/si-score-order-baseline.log`, `/tmp/si-score-order-focused.log` (synthetic score diagnostics), `/tmp/si-score-order-final-focused.log`, `/tmp/si-score-order-final-tests.log` and `/tmp/si-score-order-final-build.log`. See [ranking](UNIFIED_RANKING.md) and [manual checks](TESTING.md).

## Single-word first-page alternatives — 2026-10-23

With empty learning, synthetic `xianshi` produces `西安市` (-9.275), `先是` (-9.989), `显示` (-10.819) and `现实` (-11.157) in both Chinese-only and bilingual searches, including provisional results. Higher scores lead. The first two receive positive beginning-of-sequence word-context bonuses; `显示` has the highest dictionary weight among exact `xian'shi` words. The window previously inserted seven prefixes after the first two whole choices, moving `显示` from engine position 3 to window position 10.

For a single-lexical-unit leader, the window now retains the first five whole choices in engine order before featuring shorter prefixes. Sentence leaders retain their two-whole/word-selection presentation. App History still follows the first two whole choices. Engine scores and dictionary weights are unchanged.

- All three `XianshiRankingTests` pass: Chinese-only/bilingual, separated/unseparated spelling, provisional/full searches, compact/expanded layouts, first-page homophones, exact numbered commits, retained prefixes/literal, history position and the 27-choice bound.
- `./scripts/test.sh` runs 326 tests: Settings (3) and Storage (12) pass; Presentation (65) reports 12 issues and Core (246) reports 51. Failing test/location signatures and occurrence counts match the existing punctuation-validation baseline; the full suite still fails. A separate comparison against the original selection implementation also retains the same 12 focused presentation issues.
- `./scripts/build.sh` passes for the Debug app with signing disabled. SwiftPM/Xcode checks required normal build/cache access outside the restricted sandbox.

No app was installed or launched. Native host typing, keyboard/mouse routing, focus/shortcuts, VoiceOver and candidate positioning remain unverified. Local synthetic evidence: `/tmp/si-xianshi-diagnostic.log`, `/tmp/si-xianshi-baseline.log`, `/tmp/si-xianshi-focused.log`, `/tmp/si-xianshi-regression.log`, `/tmp/si-xianshi-final-tests.log` and `/tmp/si-xianshi-build.log`. Manual checks are in [testing](TESTING.md).

## Language-labeled punctuation — 2026-10-23

Common ASCII punctuation now offers explicit English/Chinese variants in the shared engine and Settings preview. Mapped punctuation starts composition with an enabled language; complete word/sentence choices can retain the trailing mark or use its Chinese alternatives. The original spelling stays available, apostrophes inside Pinyin retain their separator role, and optional delimiter-confirmation policies remain in place. Compact and expanded rows show small E/C badges immediately after punctuation text, with A for As Typed; tooltips and accessibility retain full language descriptions. Selection commits only the chosen text without an extra space or vocabulary/context learning.

- All eight new core punctuation tests and the new AppKit presentation test pass. The focused punctuation, composition-boundary and candidate-view selection passes all 35 tests. Synthetic offscreen light/dark snapshots show E/C/A badges immediately after the text without overlapping punctuation in both layouts; these are view renders, not native host screenshots.
- `./scripts/test.sh` runs 323 tests: Settings (3) and Storage (12) pass; Presentation (62) reports 12 issues and Core (246) reports 51. An isolated, unmodified `HEAD` snapshot runs 314 tests with the same 17 failing test names and identical per-test issue counts. No new full-suite failure is observed; the existing decoding/search/presentation failures remain unresolved.
- `./scripts/build.sh` succeeds for the Debug app with signing disabled. SwiftPM/Xcode checks required normal build/cache access outside the restricted nested sandbox. Whitespace checks and all 37 checked local documentation links pass.

No app was installed or launched, and enabled input sources, running input-method processes and private archives were not changed. Live host input, focus/shortcuts, spoken VoiceOver and native candidate positioning remain unverified. Manual steps are in [testing](TESTING.md#language-labeled-punctuation-candidates). Local evidence: `/tmp/si-punctuation-focused.log`, `/tmp/si-punctuation-all-tests.log`, `/tmp/si-punctuation-build.log`, `/tmp/si-punctuation-baseline-tests.log`, `/tmp/si-punctuation-baseline-comparison.json` and `/tmp/si-punctuation.{compact,expanded}[.dark].png`. The subtitle refinement passes all 16 candidate-view tests, preserves the same complete-suite failure signatures, and builds successfully; its final logs and renders use `/tmp/si-punctuation-subtitle-*` and `/tmp/si-punctuation-subtitle.{compact,expanded}[.dark].png`. The subsequent E/C/A badge refinement passes all 16 candidate-view tests and the Debug build; the full suite retains the same 12 presentation and 51 core issues. Its logs and final renders use `/tmp/si-punctuation-badge-*` and `/tmp/si-punctuation-badge.{compact,expanded}[.dark].png`.

Badge lettering now uses the visible Core Text glyph-path bounds for horizontal and vertical centering, avoiding NSTextField baseline padding. All 16 candidate-view tests and the Debug build pass; the full suite has the identical 63 recorded issues from the preceding badge check. Final light/dark renders were visually inspected in both layouts. Evidence: `/tmp/si-punctuation-badge-centered-focused.log`, `/tmp/si-punctuation-badge-centered-tests.log`, `/tmp/si-punctuation-badge-centered-build.log` and `/tmp/si-punctuation-badge-centered.{compact,expanded}[.dark].png`.

## Exact spelling weight — 2026-10-23

The reported bilingual `ma` result was reproduced with empty learning: `may`, `man`, `make`, `made`, `many`, then `吗`. The compact page contains five choices. The shared finite spelling channel now gives a complete English word or Chinese syllable sixteen times its previous geometric endpoint weight before normalization. Completing the last missing letter improves spelling evidence by five bits instead of one. Chinese still scores syllables independently of word cuts; direct English, preview, sentence/mixed edges and personal codes share their existing channel. Dictionary data, single-character insertion costs, language identity, learning and literal retention are unchanged. This is an explicit heuristic preference, not a measured population typing distribution.

- Empty-profile provisional/full execution now leads with `吗`, `ma`, `may`, `man`, `make`; `吗` moves from engine/window position 6 to 1 (score approximately -10.372). New regressions also check exact `ne` and English `man`, retained language alternatives and literal input. The new presentation test checks first-choice numbering and exact `ma` → `吗` commits in both layouts and generation stages. Both new tests fail against the prior implementation and pass with the change.
- English/Chinese finite spelling distributions still normalize over lengths 1–64. Independent arithmetic/reference fixtures were updated for the documented endpoint weight, including direct lookup, constructed sentences, lexical deduplication and frequency/completion competition. A focused selection of 28 tests passes: the `ma` presentation commit, nine candidate-scoring tests, normalization, cached-preview/cross-decoder consistency, and existing English sentence/vocabulary tests. The broader focused selection retains existing spelling-search/presentation failures; the complete baseline comparison is recorded in local logs.
- Isolated full tests run 334 tests versus the 332-test baseline. Storage (12) and Settings (23) pass; presentation (61) retains the same 12 issues and core (238) the same 51. Failing test names and per-test issue counts match the baseline; the full suite still fails. Tests use `./scripts/test.sh --disable-sandbox` because this restricted environment rejects SwiftPM's nested sandbox.
- The same Debug quality executable evaluates the 86 known synthetic fixtures before/after: first choices decrease from 67 to 65, top-five coverage remains 83, engine recall remains 83, and provisional/final first-choice agreement remains 86. `togethe` changes from `together` to `to get he`; `performa` changes from `performance` to `perform a`. Both expected completions remain within five. The already incorrect `dishiye` first choice changes from `低失业率` to `地势也`. These known fixtures demonstrate a completion/complete-word-sequence tradeoff and are not independent quality evidence or a performance measurement.
- The isolated Debug app builds successfully with signing disabled, using the existing pinned Sparkle checkout. Building required normal Xcode/SwiftPM cache access outside the restricted sandbox. The integrated workspace test attempt is blocked by a concurrent `ApplicationMemorySnapshot.swift` closure-type inference error at lines 46/61, unrelated to these spelling files. Isolation uses a tracked `1bc9d7a` snapshot plus only this task's code/test changes; ongoing application-memory work is preserved.

No app was installed or launched, input sources/private archives were not changed, and live host typing, focus/shortcut routing, VoiceOver and candidate positioning remain unverified. Local evidence is under `.build/ma-investigation/`: `isolated-baseline-tests.log`, `isolated-before-regression.log`, `isolated-final-tests.log`, `passing-focused-tests.log`, `quality-before.json`, `quality-after.json`, `results-after.log`, `isolated-final-debug-build.log` and `integrated-tests.log`. See [candidate ranking](UNIFIED_RANKING.md) and [native checks](TESTING.md).

## Shared candidate scoring — 2026-10-23

This checkpoint supersedes the language-category placement and separate full-score formulas described in earlier records. `CandidateScoring` supplies the same word insertion/frequency, spelling and language-transition units for Chinese, English and mixed paths. Chinese syllable offsets and the mixed leader's fixed front seat are removed. Chinese word-context evidence is applied to direct choices and mixed Chinese runs as well as Chinese sentences. Exact pinned personal phrases remain overrides; unpinned phrases now use the same 10,000-weight prior/code cost in direct and constructed paths, independently of dictionary size. Dictionary weights, consent and retained personal data are unchanged.

- Eight new `CandidateScoringTests` pass, including seven synthetic inputs under the score-order parameterized check. They cover `ling` in provisional/full results, direct/prefix word and context consistency across lanes, English sentence/mixed token costs, completion costs, disabled languages, canonical identity, literal fallback, personal pins and separator/dictionary-size-independent personal costs. The added presentation regression passes: `零` remains ahead of protected `里NG` in the shortlist, identities/literal survive, and expanded numbering commits the exact selected character.
- With both languages enabled and learning empty, `ling` gives `零` a base score of approximately -19.076 and `里NG` approximately -28.388. They appear at engine positions 7 and 95 respectively. English completions `lingo` and `linger` compete by score, so five Chinese compact entries are not guaranteed. The window still preserves mixed availability within its 27-item shortlist. These are heuristic scores from synthetic core execution, not normalized probabilities or native-host observations.
- The pre-change full baseline ran 323 tests: storage (12) and Settings (23) passed, presentation (59) reported 12 issues, and core (229) reported 60. After this change the full run executes 332 tests: storage (12) and Settings (23) pass; presentation (60) retains 12 issues and core (237) retains 51. Every remaining failing test name occurs in the baseline. Formula-dependent arithmetic fixtures and assumptions of reserved exact/language/phrase front positions were updated to the new documented contract; the separate legacy beam/quality failures remain active. The full suite still fails.
- Tests used `./scripts/test.sh --disable-sandbox`: the ordinary command's nested manifest sandbox was rejected by this restricted execution environment. The flag disables SwiftPM's nested sandbox, not source checks. No assertions were filtered from the full run.
- The Debug app builds successfully with signing disabled. Native host typing, focus/shortcut routing, VoiceOver and live candidate-window behavior remain unverified. No app was installed or launched, and no input-source settings, private archive, commit or published artifact was changed.

Local diagnostic evidence is in `/tmp/si-word-boundary-baseline-tests.log`, `/tmp/si-unified-final-tests.log`, `/tmp/si-unified-regressions.log`, `/tmp/si-unified-inspect.log` and `/tmp/si-unified-build.log`. See [candidate ranking](UNIFIED_RANKING.md) and [manual checks](TESTING.md) for the current formula and outstanding integration work.

## Mixed English lookup — 2026-10-22

`deploy` already existed in the English dictionary, but the facade ran Chinese and English as independent monolingual lanes. Mixed-provider calls returned no candidates. The shared `LexicalCompositionDecoder` now joins complete Chinese-word readings from the existing ChineseLexicon with English trie matches/completions, using the common integer weight unit. The Chinese-only decoder retains its established sentence objective. No dictionary entries, corpus weights, personal storage or consent were changed, and no word-specific rule was added.

`woxiangyaodeploy` and `wo'xiang'yao'deploy` now lead with `我想要deploy` in provisional/full results. English case, interleaved words and final English completion are retained. Exact English words and fully lexical English sentences retain their identity/spacing, while complete Chinese readings keep their Chinese leader. Mixed initials, Chinese-tail prediction, correction, trigram rescoring within mixed paths and broad language-boundary detection remain incomplete. Bounded verbatim paths stay excluded from learning/context, and mixed candidates supply no automatic-confirmation evidence.

- All seven new `MixedLexicalIntegrationTests` pass, covering the report, disabled languages, exact English/Chinese leaders, case/interleaving/completion, commits, exact umlaut prefix boundaries, stale cancellation/configuration results and personal/verbatim privacy. Existing `MixedInputTests`, `EnglishSentenceTests` and `EnglishVocabularyTests` pass.
- `./scripts/test.sh` runs 323 tests. Storage (12) and Settings (23) pass; presentation (59) retains 12 assertion issues and core (229) retains 60. Before integration the 316-test baseline had 27 presentation and 104 core issues. Recorded remaining failure signatures are a subset of the baseline. The sequential-selection test now checks character-choice reachability and preservation of the first two engine whole choices, accounting for a newly protected mixed whole identity rather than assuming a fixed fourth row or two Chinese-only wholes. The full suite still fails; remaining migration quality/learning/presentation problems are not declared resolved.
- The Debug app builds for arm64/x86_64 with signing disabled. The Release synthetic benchmark completes with 200 timed iterations per scenario. For `woxiangyaodeploy`, median/p95 are 6.684/7.914 ms; interleaved `woaiSwiftshurufa` measures 2.588/2.896 ms. The ten-repeated-`fangan` case measures 97.175/102.453 ms, and 64 repeated `a` letters measure 87.029/89.409 ms. These use synthetic 5,000-entry preferences and 1,000 personal phrases; they are in-process measurements, not native event latency or a speedup claim.
- Documentation local-link checks and whitespace checks pass. No installation, app launch, native host typing, VoiceOver inspection, private-data read, commit or publication was performed. The currently installed input method is unchanged.

Local evidence: `.build/mixed-lexical-tests.log`, `mixed-lexical-focused.log`, `mixed-lexical-regressions.log`, `mixed-lexical-build.log`, `mixed-lexical-benchmark.json` and `mixed-lexical-benchmark.log`. Native checks are listed in `docs/TESTING.md`.

## Shared English/Chinese dictionary contract — 2026-10-22

English now has a pinned weighted text snapshot, a public `si-entries.json` overlay, and a generated read-only SQLite database. It retains all 63,602 canonical word forms from the existing imports. Both languages use identical schema/index definitions, a shared immutable reader and the fixed dictionary-relative frequency unit in `Data/DictionaryFormat.json`. The initial English wordfreq estimates are converted once into that unit; ordinary builds apply public edits without reimporting sources or rescaling stored weights. Original pins and notices remain. Generated English word/frequency Swift arrays have been removed.

- All 34 Python maintenance tests pass, including English additions/exclusions/weight/case edits, source/notice validation, output preservation, shared schema/unit and initial conversion checks. Both dictionary `build --check` commands, retained spelling-import checks and ranking notice/calibration checks pass offline. Chinese context checksums remain pinned and verified.
- A direct comparison against the pre-change Git database confirms all 953,710 Chinese rows, source keys, weights and rowid order are identical. Only shared metadata and empty ASCII-initial buckets were added.
- `./scripts/test.sh` runs 316 tests, including the three new database tests (one parameterized for incompatible units/scales). Storage (12) and Settings (23) pass. Presentation (59) still has 27 assertion issues; Core (222) still has 104. The baseline ran 313 tests with the same 27/104 issues. Recorded failure test/expectation signatures match after ignoring shifted source line numbers. The full suite still fails; the existing migration defects are not resolved by dictionary-format unification.
- Debug and Release app builds succeed for arm64 and x86_64 with signing disabled. Xcode now preserves both language directories rather than flattening same-named manifests. Both packaged databases and manifests match the generated source hashes, without stale flattened database copies. All 75 local link targets in changed documentation resolve; whitespace checks pass.

No installation, app launch, live host typing, VoiceOver check, private-data read or publication was performed. Dictionary-unit parity does not establish common-corpus statistics, calibrated complete sentence scores, restored mixed lexical paths or host compatibility. Existing candidate placement and decoder objectives remain in place; English probability rounding can cause small score differences.

Local evidence: `.build/english-db-baseline.log`, `english-db-tests.log`, `english-db-focused.log`, `english-db-data-tests.log`, `english-db-chinese-check.log`, `english-db-import-check.log`, `english-db-debug-build.log` and `english-db-release-build.log`. The focused pre-final run contains the same existing mixed-path failures; the final complete run includes all new resource tests.

The subsequent readable-weight view adds `Data/English/SI/generated/weights.tsv`: all 63,602 effective English entries, sorted by descending weight after public SI edits. Builds regenerate it and `--check` rejects stale exports. All 35 Python maintenance tests pass; the Debug app build passes, and the full Swift suite retains the identical baseline failure signatures. Evidence: `.build/english-weights-data-tests.log`, `english-weights-tests.log` and `english-weights-build.log`.

## Ambiguous complete syllable cuts — 2026-10-22

The reported `woxianganzhao` first choice was `我先感召`. The primary cut is `wo / xian / gan / zhao`; the equally short `wo / xiang / an / zhao` was excluded from sentence search. Alternative full-key dictionary lookup did not help because `我想按照` is constructed from multiple words. This is a search-coverage defect before sentence ranking, not evidence that the desired words are absent from the dictionary.

Up to 32 uncorrected complete minimum-syllable cuts now share the existing bounded lattice and base/personalized beams. Edges carry source start/end offsets, so only compatible spelling spans join. Repeated spans share lookup work; lexical prefixes include alternative cuts, and composed-prefix ranking groups paths by their actual consumed source boundary. The word-frequency/context formula, data resources and learning retention are unchanged. Higher-syllable-count cuts, general typo decoding and semantic accuracy remain outside this fix.

- Before the fix, the initial four focused tests report 11 assertion issues. After the fix, all seven final `ChineseSegmentationTests` pass, including the reported sentence in provisional/full searches, Chinese-only/combined languages, partial/explicit separators and a longer input; synthetic frequency/order, prefix commits, learning/clear, confirmation disagreement and 32-cut bounds also pass.
- `./scripts/test.sh`: 313 tests run. Storage (12) and Settings (23) pass; presentation (59) retains 27 assertion issues and core (219) retains 104. Compared with a fresh 306-test baseline, the assertion locations/messages and counts are identical. The full suite still fails; existing migration defects remain unresolved.
- `./scripts/benchmark.sh`: Release synthetic measurements complete with 200 timed iterations per scenario. For `woxianganzhao`, median/p95 are 4.053/4.225 ms; ten repeated `fangan` spans measure 54.994/56.919 ms. These are in-process timings with the benchmark's synthetic 5,000-entry learning profile and 1,000 personal phrases, not host-event latency or a before/after speedup. `./scripts/benchmark.sh --quality` retains 68/86 first choices across the known repository fixtures, with preview/final first-choice agreement on all 86; this is regression evidence, not independent semantic accuracy.
- `./scripts/build.sh`: Debug app builds successfully for arm64 and x86_64 with signing disabled. No installation, app launch, live host typing, VoiceOver check, private archive read or publication was performed. The installed input method has not been updated by this task.

Local logs/reports: `.build/ambiguous-cut-baseline.log`, `ambiguous-cut-before.log`, `ambiguous-cut-tests.log`, `ambiguous-cut-debug.log`, `ambiguous-cut-benchmark.json` and `ambiguous-cut-quality.json`.

## Frequency and segmentation balance — 2026-10-22

The user requested stronger dictionary-frequency influence after `nawomenzaichaxun` produced `那我闷在查询`. Read-only SQL/context inspection and a standalone probe linked against the existing shared core reproduced the base result without personal learning. The winning split was `那我 / 闷在 / 查询`; `我们` itself has weight 13,696,325, while `闷在` has weight 3,036. The source data was not changed.

SI now uses `ln(max(1, weight)) + 20 × (syllables - 1) - (syllables == 1 ? 2 : 0)`. The extra single-character cost drops from upstream's `ln(1e6)` (about 13.82 nats) to two nats. This is an intentional local algorithm divergence, not an upstream-equivalence claim. The shared log-frequency coefficient, existing 20-nat token insertion prior, context models, beams, source bounds, separate base/personalized lanes and preference limits remain. No word-specific scoring or exclusion was added.

Exploratory offline calculations used only the development examples and reported cases to compare common token insertion costs from 8 to 24. Large reductions broke ordinary sentence boundaries; retaining 20 and testing character costs from zero to eight preserved a useful range at one to four. Removing the character cost entirely introduced `好的我指导了` on the historical `haodewozhidaole` fixture; a small cost prevents it. That historical holdout was inspected during validation and now informs a named regression guard for this change. It must not be presented as untouched independent generalization evidence. The selected two-nat cost also lets a tenfold frequency advantage beat a competing all-multi-character segmentation in a separate injected fixture.

| Synthetic input | Before first choice | After first choice |
| --- | --- | --- |
| `nawomenzaichaxun` | 那我闷在查询 | 那我们在查询 |
| `nengxiangbanfayouhuama` | 能像办法优化吗 | 能想办法优化吗 |
| `haodewozhidaole` | 好的我知道了 | 好的我知道了 |
| `julitebieyuan` | 距离特别圆 | 距离特别圆 — still wrong for the requested 远 |
| `bangwozaixie` | 帮我在写 | 帮我在写 — still wrong for the requested 再 |

- Before/after standalone Debug probes linked the actual shared core with empty private profiles. Across 45 development examples, first-choice accuracy changes from 35 to 36; historical holdout stays 15/20; phonetic regressions stay 17/21. Two reported cases change from 0/2 to 1/2. Preview first choices have the same counts. None of these 88 examples loses a previously correct first choice. These are small, known synthetic sets, not a representative language benchmark.
- `./scripts/benchmark.sh --quality`: Release evaluation passes and reports 68/86 first choices for the three retained repository partitions. The two extra reported cases above are covered by probes/tests, not included in that tool's 86-row total. The report's model name now describes the Chinese lattice and independent English model accurately.
- `./scripts/test.sh`: ran 306 tests. Storage (12) and Settings (23) pass; presentation (59) still reports 27 assertion issues, and core (212) reports 104. Total issues fall from 135 to 131. Comparison with the prior log finds no newly failing test names or increased assertion count within an already failing test. The full command still fails; it is not a green regression baseline.
- All 19 focused Chinese frequency/migration/everyday-quality/English-preservation/homophone tests pass. Five new tests cover the reported case in full/provisional searches, enabled-language combinations, apostrophes, exact prefix/literal boundaries, tenfold frequency competition, over-splitting, rare-word availability, and explicit preference override with the base path retained. Arithmetic fixtures were updated only for the deliberate new score/output and independently checked against SQL/ngram calculations.
- `./scripts/build.sh` and `./scripts/build.sh Release`: passed for arm64 and x86_64, signing disabled; only the existing AppIntents metadata warning remains. Both packaged dictionaries match the unchanged manifest hash `b55d65ba5a30f4061cec30ebf7d89b9fadb974dcebdfa923faebab45e8a680c1`. Whitespace and local Markdown target checks pass.
- No installation, application launch, live host typing, VoiceOver check, new data import, private archive access or publication was performed. Context-sensitive 在/再 and 远/圆 mistakes remain unresolved. The change improves the observed frequency/segmentation imbalance without establishing semantic quality, broader generalization or host compatibility.

Local probes, calibration results and logs are in `.build/frequency-ranking/`; the fixed before/after outputs are `quality-before.json` and `quality-after.json`, with `quality-release.json`, `full-tests.log`, `final-focused.log`, `debug-build.log` and `release-build.log` recording the checks above.

## Dictionary consolidation — 2026-10-22

The user requested MSIME as the sole Chinese dictionary source and explicitly retained existing English functionality and vocabulary. Removed the former direct Rime Chinese snapshots, original SI tables, generated Swift Chinese table, old Chinese adapter/tests and old notice. The pinned MSIME snapshots, public SI overlay, SQLite and context resources remain. Private archives were not accessed or changed. English data, its runtime implementation and the automatic-confirmation implementation match the pre-consolidation checkout.

- `python3 scripts/msime_dictionary.py build --check`: passed with 953,710 entries. Source/overlay hashes, generated dictionary/manifest and pinned context resources match. SQLite integrity returns `ok`. The check also supports equivalent schema, row order, data and indexes across SQLite versions without replacing outputs; the retained binary must still match its recorded hash.
- `python3 -m unittest discover -s Tests/VocabularyTests -v`: all 27 tests passed, including six new MSIME pipeline fixtures for source checksum failure, overlay validation/merging/ties, read-only checks, SQLite-version header compatibility/index loss, context checks and mocked upstream audit. The actual network audit was not run.
- `./scripts/vocabulary.sh build --check` and `python3 scripts/ranking.py --check`: passed for the retained English data.
- `./scripts/test.sh`: ran 301 tests. Storage (12) and Settings (23) pass; presentation (59) has 27 assertion issues, and core (207) has 108. The full command fails. Compared with the previous 136-issue checkpoint, replacing the obsolete homophone fixture with actual MSIME weights removes one stale assertion; other existing quality/behavior failures remain visible.
- A focused run of Chinese migration, consolidation, everyday sentence quality, homophone-weight and polyphonic-reading checks passed all 15 tests. It preserves the existing everyday-sentence quality gate and checks that `ne` leads with `呢` while English `new`/`need`/`next` and literal input remain available.
- `./scripts/build.sh` and `./scripts/build.sh Release`: passed for arm64 and x86_64, signing disabled. Both bundles contain copies identical to current Chinese resources, retain English vocabulary/ranking notices, and omit the obsolete Chinese notice. Only the existing AppIntents metadata warning remains.
- Whitespace and local Markdown target checks passed. No installation, launch, native host typing, live UI/VoiceOver check, publication or private-data migration was performed. Full regression failure and Chinese quality limitations remain unresolved.

Local logs are `.build/msime-only-{dictionary,maintenance-tests,english-check,ranking-check,tests,focused,debug,release}.log`. Historical records below describe earlier source/data states.

## Swift Chinese migration validation — 2026-10-22

The user authorized validation. **The migration is not ready: compilation succeeds, but full regressions and Chinese quality still fail.** Existing pre-migration pass counts below do not apply to this worktree.

- `./scripts/build.sh` and `./scripts/build.sh Release`: passed for arm64 and x86_64 with signing disabled. Only the existing AppIntents metadata warning remains. Both app bundles contain byte-identical copies of the SQLite dictionary, manifest and two context models. No app was launched or installed.
- `./scripts/test.sh`: ran 289 tests across four targets. Storage (12) and Settings (23) pass. Core (205) reports 109 issues; presentation (49) reports 27 issues. These are assertion issues, not counts of distinct defects. The complete command exits unsuccessfully.
- All 13 newly added tests pass: nine Chinese resource/lookup/boundary/scoring/evidence/binary-format checks, one libc++ ordering comparison across five tied-score batch sizes, and three asynchronous Settings preview checks for replacement, consent recheck and cancellation/reopening. The new tests do not establish overall language quality.
- Rebuilt the dictionary into `.build/chinese-dictionary-rebuild` from retained snapshots and overlay. SQLite and manifest bytes match the packaged sources exactly; `PRAGMA integrity_check` returns `ok`, with 953,710 entries. Both context-file lengths and SHA-256 values match `resources.lock.json`.
- Initial compilation found an ambiguous map/sort expression in prefix selection; explicit tuple typing fixes it. Regression checks also found that collecting automatic-confirmation evidence emitted extra visible sentences. Hidden alternatives now veto disputed boundaries internally, while visible candidate IDs, scores and exact output bytes remain unchanged. Incomplete trailing syllables now retain valid preceding composed prefixes without inventing a whole sentence.

Observed Chinese-only first choices on synthetic development inputs:

| Input | Actual first choice | Quality interpretation |
| --- | --- | --- |
| `ne` | 呢 | Reported single-syllable problem is resolved in the shared core; English `new` remains available when enabled |
| `julitebieyuan` | 距离特别圆 | Still fails the requested 距离特别远 outcome |
| `bangwozaixie` | 帮我在写 | Fails the existing 帮我再写 quality fixture |
| `nengxiangbanfayouhuama` | 能像办法优化吗 | Fails the existing 能想办法优化吗 quality fixture |

An independent Python calculation of SQL spans, lexical natural-log scores and binary ngram increments reproduces the four arithmetic fixtures in `ChineseMigrationTests`, including the undesirable results. For `julitebieyuan`, the winning words are `距离` + `特别圆`: the pinned source contains `特别圆 / te'bie'yuan / 3984`, and the multi-syllable edge bonus favors that path. This comparison checks a simplified calculation with these pinned resources; it does **not** execute MSIME's full application/session or establish what the user's installation does. No per-word scoring exception was added and the desired quality failure remains open. The pinned shared host preference source also confirms both neural switches default to false, independently of engine session defaults.

Remaining failures include old mixed-language requirements deliberately deferred by the objective, former score/beam expectations incompatible with the new algorithm, and unresolved learning, prefix-presentation and automatic-confirmation behavior. They remain visible rather than being disabled or rewritten to make the suite green. Continuous automatic confirmation does not activate in two prior standard-vocabulary fixtures; native typing, focus, shortcuts, VoiceOver and host compatibility are unverified. No input source, installed app, user archive or running input-method process was changed.

Raw local evidence: `.build/chinese-validation-tests.log`, `chinese-validation-debug.log`, `chinese-validation-release.log`, `chinese-migration-focused.log`, `chinese-dictionary-validation.log`, and `chinese-reference-results.json`. Reference ordering fixtures were generated with Apple clang/libc++ `std::sort` and `std::partial_sort` using a score-only record comparator. These are regression and arithmetic checks, not a production accuracy estimate.

### Reported abbreviated input — 2026-10-22

Synthetic `jintjiushi` reproduces the reported list: the primary cut is `jin / t / jiu / shi`, with no complete alias reading. Sentence edges require complete syllables, so the abbreviated `t` leaves no whole-sentence lattice path. Direct full-input lookup has no matching word, and the remaining Chinese results are prefix choices such as 今天 and 尽头. This is a decoding-coverage limitation, not a comparison of 今天 and 今天就是 by frequency. Full `jintianjiushi` and explicit `jin'tian'jiu'shi` both lead with 今天就是.

Two focused characterization/commit tests pass: 今天 consumes exactly `jint`, leaving `jiushi` editable with 就是 available; full spellings supply the whole sentence and preserve exact literal input. No production behavior was changed for this diagnosis. Logs: `.build/reported-abbreviation.log` and `.build/reported-abbreviation-regression.log`. The 289-test complete run above predates these two follow-up tests and was not repeated solely for them.

A read-only process query found one SI process at the installed input-method path. Its dictionary, manifest and two context files match the worktree by SHA-256. The screenshot shows a marked-Pinyin area above the custom horizontal candidate panel. The controller calls the host's `setMarkedText` separately from displaying its `CandidatePanel`; it does not construct an `IMKCandidates` list. This establishes the roles of the two visible areas, not whether a separate, unpictured window can appear. No process, installed app or input source was changed.

## Candidate refresh follow-up — 2026-10-22

The user clarified that another window briefly appears at the lower-left display corner on keystrokes while SI's candidate panel also flickers. The earlier screenshot alone did not capture that transient window, so its owner and exact cause remain unconfirmed.

Source inspection found that each append, accepted provisional result and accepted full result called the host's `setMarkedText`, even when composition bytes and UTF-16 selection were unchanged. Candidate rendering also removed/recreated all visible row views, and window resizing synchronously painted before completing row layout. The controller now deduplicates identical host updates with client/composition-local `MarkedTextState`, resets that state across commit/cancel/deactivation/client changes, and checks the active client before async delivery. Unchanged visible identities reuse rows, while changed identities still invalidate removed controls. Panel layout completes before display.

The final `./scripts/test.sh` run executes 295 tests. The four new refresh test methods pass, including both compact/expanded parameter cases, candidate-only delivery without extra host sends, caret updates, cancellation/reset and exact UTF-8/UTF-16 behavior. Storage and Settings pass; the core/presentation targets still report the same 109/27 assertion issues recorded before this fix. This is not a green full suite. Debug and Release compilation pass with signing disabled. Logs: `.build/candidate-refresh-tests.log`, `.build/candidate-refresh-debug.log` and `.build/candidate-refresh-release.log`.

The targeted computer-use read of SI's window was rejected by automatic approval review because it would send accessibility content and screenshots, potentially containing sensitive composition text, to the computer-control connection. No alternate capture/control backend was used. Native flicker and transient-window ownership remain unverified. The installed app and running input-method process were not changed; these source/build changes are not yet an installed fix.

## Candidate ownership and anchor follow-up — 2026-10-22

The user reported that flashing persisted after the first refresh changes. The installed executable's arm64 and x86_64 UUIDs match the preceding Release build; this checks the file on disk, not the image loaded by a process. The previous change removed redundant host writes and row recreation, but did not address multi-controller window ownership or geometry-channel switching.

Added a failing geometry regression before changing `CandidateAnchor`: after a valid document rectangle, ten temporary document-query misses with a valid-looking inline rectangle at `(0,0)` moved the anchor into the screen corner. The old implementation produced 11 assertion issues. The fix retains an established document anchor through temporary misses, still follows fresh document geometry, and invalidates caches on reset/disconnected displays. Legacy-only hosts retain their initial fallback path. This proves a concrete corner-jump path, not the identity of the unobserved native window.

Candidate panels now have one weak main-actor visibility owner, claimed only by activation/current key handling. Superseded panels hide and cannot reclaim visibility from late results, timers or row actions; late old-client deactivation cannot release the new owner's lease. Buffers and selections remain per client. Host text/geometry calls also receive per-controller revision checks against synchronous reentry, and geometry resolves on a local value copy. The SDK declaration of `activateServer:` was checked; its bridge retains the existing IMK main-thread assumption. MSIME's pinned macOS controller independently uses a weak candidate-panel owner for missed deactivation; see `platforms/macos/src/input/InputController.mm` at the retained engine revision.

`./scripts/test.sh --filter 'CandidatePanelOwnershipTests|CandidatePlacementTests|MarkedTextStateTests|CandidatePipelineTests'` passes 20 tests across four suites. Offscreen panel tests reject old-client render/show requests without showing a test window. Final complete regression executes 298 tests: storage (12) and Settings (23) pass; presentation (56) and core (207) retain their prior 27/109 assertion issues. Debug and Release app builds pass with signing disabled. Logs: `.build/candidate-anchor-before.log`, `candidate-ownership-focused.log`, `candidate-ownership-tests.log`, `candidate-ownership-debug.log`, and `candidate-ownership-release.log`.

The new build has not been installed or launched, and no running input method was stopped. No screenshot, accessibility read, window capture workaround or native typing was performed after the earlier approval rejection. Live flicker, first-frame fallback geometry and native callback/reentry ordering remain unverified; the automated results must not be presented as confirmation that the user's flicker has disappeared.

## Candidate coordinate-source correction — 2026-10-22

A subsequent screenshot shows a stationary candidate panel at the left edge while marked input is in the right-hand editor. The prior document-first/cached-document policy did not establish a correct anchor. It is superseded here: retaining a rectangle through failures cannot establish that its original coordinate source was correct.

The SDK's `IMKInputSession.h` explicitly provides `attributesForCharacterIndex:lineHeightRectangle:` for candidate-window placement. It is now primary, queried at inline-session UTF-16 offset zero and then the current composition offset when needed. Fresh inline geometry replaces any cached document fallback. An established inline position survives temporary misses; `firstRectForCharacterRange:actualRange:` is only a fallback and its returned actual range must contain the requested insertion position. Unknown, unrelated and overflowing actual ranges are rejected. Ambiguous global-origin results require independent geometry corroboration. Activation clears both anchor and marked-text caches, including when an IMK controller/client wrapper is reused.

The updated source-priority regression first failed on the preceding implementation with five assertion issues: a displaced document rectangle near `(8,8)` overrode a valid inline caret in the right-hand editor. It passes after the correction. Additional regressions cover recovery from that cached document fallback, actual-range validation, origin corroboration and retention during temporary failures. The previous test's requirement to avoid inline queries after document success was removed: that policy prevented recovery to a fresh correct inline coordinate. Existing reflow, source-boundary, disconnected-screen, ownership and cache-isolation checks remain.

The focused coordinate/ownership/marked-text command passes 19 tests. Final `./scripts/test.sh` executes 301 tests: storage (12) and Settings (23) pass; presentation (59) and core (207) retain the preceding 27/109 assertion issues. Debug and Release builds pass with signing disabled. Logs: `.build/candidate-coordinate-before.log`, `candidate-coordinate-focused.log`, `candidate-coordinate-tests.log`, `candidate-coordinate-debug.log`, and `candidate-coordinate-release.log`.

No application was installed/launched, no process was stopped and no native capture/typing was performed. This is an implemented and automatically checked coordinate-source correction, not proof that the installed input method is positioned correctly in the user's live host.

## Swift Chinese migration — 2026-10-21, historical code-only checkpoint

The current worktree contains a new Swift MSIME-derived Chinese decoder, packaged SQLite dictionary and word-context resources. The retained source snapshots generated 953,710 unique lexical entries; generation is a maintainer data operation, not compilation or an engine check. Source revisions and resource hashes are recorded under `Data/Chinese/MSIME/` and in the packaged manifest. New Settings preview search runs on a worker actor with stale-result rejection.

At this historical checkpoint, the user had prohibited tests, compiler runs, app builds, benchmarks, installation and native typing checks for the migration. That restriction was lifted on October 22; the newer record above supersedes this checkpoint. Prior pass counts, quality figures and performance measurements below apply to the previous implementation. They must not be attributed to the new Chinese engine. Default-algorithm fidelity, optional correction/neural work, packaging and independent quality comparison remain in [the implementation plan](IMPLEMENTATION_PLAN.md).

Further source alignment ports MSIME's streaming heap selection and terminal libc++ introsort tie movement to Swift, keeps natural-log accumulation through sentence rescoring, reuses each previous-word bigram row within a column, and separates prefix presentation pools from continuation selection. Explicit Pinyin chunks now cut independently; an invalid chunk cannot erase valid preceding prefixes. Default alternative readings use the upstream gates, table-name ordering and 128-row pages per table; the earlier global-cap interpretation was corrected after reading the actual batch function. Main-query word deduplication precedes page-count policy, and split-initial rows retain primary word identities. The user confirmed default MSIME settings as the comparison target, so optional AI and general autocorrection are outside that baseline. These are source edits only, without executable validation.

The user subsequently requested the latest open-source code. GitHub branch metadata and Git object IDs show default develop at d05c33e54ff72673fd583f5ac0f79c4fe5688560, with unchanged Chinese algorithm subtrees and runtime session files relative to the retained engine snapshot; dictionary main remains b32ac7227135255a3351f02ec5bdfc983741e81a. The source-only review is recorded in `Data/Chinese/MSIME/upstream-review.json`. No runtime or quality conclusion follows from those matching upstream objects.

Personal-code integration was adjusted so a saved code cannot erase the canonical Chinese reading. Separate supplemental cuts emit only personal-derived paths; all direct personal prefixes remain independent of constructed fanout, and typed apostrophe constraints apply to saved nodes. The upstream 10,000 insertion prior is named explicitly and the one-bit pin preference is retained. Direct personal choices are ordered deterministically. These changes have not been executed or tested.

## General scoring without ordinal exceptions — 2026-10-21

The hand-authored `第 + numerals + continuation` class and all associated transition tables, cached entry effects and search states have been removed at the user's request. All Chinese entries now use the same vocabulary-derived character-boundary model. Per-syllable Chinese spelling likelihoods, the unchanged English word-prefix channel, bounded full-spelling protection and abbreviation preview coverage remain. No external model/data or per-phrase score was introduced.

A regression relabels the characters of an injected vocabulary while preserving weights, readings and the adjacency graph, and checks identical conditional scores for corresponding words, English and unknown outcomes. This guards against hidden character-specific evidence. Ordinary normalization, bounded compaction, personalized search, literal preservation and both-layout commit tests also remain.

Current synthetic quality is **72/86 first**, **73/86 top five**, **75/86 engine target recall** and **73/86 provisional top five**; first choices agree between stages on all 86. The 45 development cases are 45/45 first, the 20 historical cases are 19/20 first and 20/20 top five, and the 21 phonetic cases are 8/21 first, 8/21 top five and 10/21 recall. `dierye` and `di'er'ye` again omit `第二页` from returned results; `第二爷` and `第二月二` remain ahead. These unresolved cases remain in the quality fixtures rather than receiving a structural exception. The withdrawn experiment's higher counts below must not be attributed to this version. None of these inspected suites is an independent production accuracy estimate.

The complete current worktree passed **270 Swift tests** (193 core, 45 presentation, 20 settings, 12 storage), the Debug app build, local documentation link checks and whitespace checks. This includes concurrent automatic-confirmation work; that feature was not changed as part of removing the ordinal rule. Raw evidence is in `.build/ranking-generic/tests.log`, `debug-build.log` and `quality.json`/`.log`. No installation, live host typing or VoiceOver validation was performed. No new performance claim is made; the experiment's timings below describe the removed version.

The ranking-only staged snapshot was also validated independently before commit: all **256 Swift tests** (180 core, 45 presentation, 19 settings, 12 storage) and **33 Python data tests** passed without the separate automatic-confirmation changes. Logs are `staged-tests.log` and `staged-data-tests.log` under `.build/ranking-generic/`.

## Withdrawn ordinal-context experiment — 2026-10-21

This experimental checkpoint was withdrawn at the user’s request: its hand-authored ordinal class has been removed. Results and timings in this historical section describe the removed version, not the current engine.

Chinese observations now use per-syllable geometric likelihoods, while English retains its word-prefix channel. Equivalent exact Chinese spellings have the same cost across lexical segmentations. A small ordinal continuation class derives normalized Witten–Bell evidence from existing `第…` vocabulary entries across token boundaries. Raw dictionary weights and English frequency data are unchanged; no external model, corpus or runtime dependency was added. This is limited vocabulary structure, not sentence semantics. See [the model and its limits](UNIFIED_RANKING.md).

Continuation and terminal lanes retain twelve general paths plus at most two additional full-spelling paths, independently selected. Three ordinal suffix states retain distinct future contexts. Provisional lookup also includes bounded initial/mixed readings and sixteen full-spelling homophones per span. A 1,024-alternative synthetic test checks insertion-order-independent terminal compaction. Direct lexical/personal results, literal input and learning exclusions remain intact.

The baseline is committed core `351c35e`, archived locally without user records. Both versions ran the same 86 synthetic fixtures; the baseline harness was extended only to read the new fixtures.

| Synthetic partition | Baseline first / top five | Current first / top five |
| --- | --- | --- |
| Development regressions, 45 examples | 44 / 45 | 45 / 45 |
| Historical holdout, 20 examples | 19 / 20 | 19 / 20 |
| Phonetic regressions, 21 examples | 7 / 8 | 19 / 21 |
| Total, 86 examples | 70 / 73 | 83 / 86 |

Engine target recall is 73 → 86; provisional top-five recall is 71 → 86. Current provisional/final first choices agree on all 86. `dierye` and `di'er'ye` select `第二页` first in both stages and layouts, with exact confirmation covered by tests. Intended date, initial/mixed spelling and literal alternatives remain available. Remaining first-choice differences are `第企业` before intended `第七页` (rank five), `敌视野` before `第十页` (rank two), and `现在添加字母` before `现在添加字幕` (rank two). These are inspected, authored examples, not representative accuracy estimates. The historical holdout is no longer independent.

All **260 Swift tests** (184 core, 45 presentation, 19 settings, 12 storage), all **33 Python data tests**, `scripts/ranking.py --check`, Debug and Release builds, and whitespace checks passed. No installation, live host typing, InputMethodKit focus/event validation or VoiceOver interaction was performed.

Release full-search P95 timings on this Mac, ten warmups and 200 iterations per scenario with 5,000 synthetic preferences and up to 1,000 synthetic personal phrases:

| Scenario | Baseline ms | Current ms |
| --- | ---: | ---: |
| short | 4.819 | 5.058 |
| partial | 3.743 | 4.886 |
| phrase construction | 29.306 | 33.850 |
| mixed | 8.520 | 9.994 |
| long ambiguous composition | 86.832 | 100.512 |
| dense known composition | 20.027 | 23.590 |
| dense prefix with unknown tail | 136.119 | 152.320 |
| learned tokens in longer composition | 44.723 | 54.065 |
| English prefix | 0.137 | 0.130 |

Initialization is 689.9 → 756.7 ms outside keystroke handling. Peak benchmark-process RSS is 285.2 → 285.7 MiB, not installed-app idle memory. Additional alternatives and context increase several Chinese search costs; this is a quality/coverage tradeoff, not a latency improvement. Provisional P95 is 0.109 → 0.202 ms for short input, 1.472 → 4.223 ms for phrase construction, 0.717 → 1.803 ms for mixed input and 11.947 → 25.853 ms for long ambiguous input. These exclude host IPC, scheduling and rendering and do not establish native key-to-screen responsiveness.

Raw evidence is local under `.build/ranking-repair/`: `expanded-before-quality.json`, `ready-quality.json`, `before-performance.json`/`.log`, `final-performance.json`/`.log`, `before-previews.json`, `final-previews.json`, `ready-tests.log`, `ready-data-tests.log`, `ready-generated-check.log` and Debug/Release build logs. Reproduce with [testing commands](TESTING.md#language-specific-spelling-and-bounded-search).

## Sequential first-word selection — 2026-10-21

Constructed sentence results now present two leading whole choices followed by exact first-word and Chinese single-character alternatives, without filling later pages with more sentence completions. Language/mixed/literal reservations remain available. Synthetic `biruzhege` offers `比如这个`, a second ranked whole, `比如`, then `比`, `必`, `毕`, `笔` and other first-character choices; the second expanded page contains character alternatives instead of repeated whole-sentence extensions. Selecting `比如` consumes exactly `biru` (or `bi'ru'`) and leaves `zhege` editable for `这个`.

Transient lexical-node evidence distinguishes a single exact word/personal unit from a composed prefix or abbreviation-only match. Deduplication preserves that evidence while retaining the stronger derivation's score and identity. Prefix presentation retains up to 24 exact lexical alternatives per language/span alongside the two composed alternatives; continuation and terminal beams remain unchanged. Single-word and English-completion presentation keep the ordinary ranked shortlist. This changes selection organization, not grammatical scoring. Expanded prefix rows no longer display `First N`; tooltips and accessibility descriptions retain exact consumption information.

All 249 Swift tests (175 core, 43 presentation, 19 settings, 12 storage), the Debug app build and whitespace checks passed. Offscreen AppKit renders of both actual candidate pages were inspected in light/dark appearances. Coverage includes both search stages, language/literal reachability, paging, exact sequential source commits, bounded lexical alternatives, learning/clear, and score-preserving lexical evidence. No installation, live host typing, VoiceOver or system preference change was performed.

## Unified statistical ranking — 2026-10-20

The default English, Chinese and mixed providers now share additive negative log probabilities, with wordfreq 3.1.1 English frequencies, Chinese word/reading priors, finite spelling likelihood, language-transition calibration and vocabulary-derived Chinese character-boundary Witten–Bell backoff. Direct, composed and prefix scores use one bit scale. Explicit preferred personal codes retain categorical user priority; ordinary phrase paths use the shared cost scale. Existing aggregate learning caps, exclusions, retention and schema remain intact. See [equations, data, licensing and limits](UNIFIED_RANKING.md).

The baseline is the starting worktree at `5dafb9f`, including its pending whole-code-to-100 experiment. That experiment is removed by this implementation. Its patch/hashes and the benchmark outputs remain locally under `.build/unified-ranking/`. An isolated archive of the starting sources ran the same quality fixtures; no installed input method or saved user profile was read or modified.

| Synthetic partition | Baseline first / top five | Unified first / top five |
| --- | --- | --- |
| Tracked regression/development, 45 examples | 30 / 36 | 44 / 45 |
| Later holdout, 20 examples | 11 / 12 | 19 / 20 |

Both engines retain every target somewhere in their engine results. Unified provisional/final first choices agree on all 65 fixtures, and all 65 targets enter each stage's top five. Overall exact-target character error rate is 18.48% → 0.41%. These are small authored suites, with an intended target for ambiguous spellings, not representative accuracy estimates. The 45 tracked examples were inspected during development; the 20 holdout examples were added after freezing model parameters. No parameters were subsequently tuned against holdout results. `abilit` moves from engine rank 74 to 1 for `ability`; `danci` and explicit `dan'ci` retain first-choice `单词` through both stages and layouts without whole-code score normalization. Remaining first-choice differences include `帮我见查一下` versus `帮我检查一下` and `字母` versus intended `字幕`.

Checks actually completed:

- All **242 Swift tests** passed: 173 core, 38 presentation, 19 settings and 12 storage.
- All **32 Python vocabulary/model tests** passed; English/Chinese generation checks and ranking/source/license checksum checks passed offline.
- Debug and Release app builds succeeded with signing disabled. The bundled ranking notice bytes match the generated source notice, including full Apache-2.0 text, original data/license URI, modifications and SUBTLEX attribution. No Python runtime or third-party executable library was added.
- Native offscreen candidate renders and selection/commit checks cover light/dark, compact/expanded and narrow layouts. Synthetic PNGs are retained under `/tmp/si-unified-ranking*`. `ability` has explicit bilingual stage/layout/commit coverage, including exact literal reachability and complete-English reservation ahead of prefixes.
- Probability/unknown normalization, rare readings, character-boundary interpolation, spelling mass, independently enumerated optimal path costs, source-order determinism and Unicode committed bytes have focused regression coverage. The preview cache is compared against unbounded English ranking.

Release measurements used the same 200-iteration synthetic full-search scenarios with 5,000 preferences and 1,000 phrases, without concurrent builds/tests. Rankings and output fingerprints intentionally change from the baseline. A compact-transition/top-eight-cache refinement preserved all final fingerprints. A further per-position scratch cache increased measured instruction count and was removed. Timings are descriptive samples, not native key-to-screen latency or a blanket speedup claim.

| Full engine scenario | Baseline P95 ms | Unified P95 ms |
| --- | ---: | ---: |
| English broad prefix | 0.974 | 0.868 |
| English prefix | 0.116 | 0.113 |
| English exact | 0.145 | 0.145 |
| short | 4.500 | 4.783 |
| partial | 3.280 | 3.749 |
| phrase construction | 24.100 | 28.861 |
| mixed | 7.611 | 8.461 |
| long ambiguous composition | 74.684 | 81.085 |
| dense prefix with unknown tail | 122.355 | 121.480 |
| learned tokens in longer composition | 51.562 | 41.391 |
| bounded Unicode personal expansions | 74.556 | 26.532 |

Initialization is 470.2 → 697.4 ms once per process, outside keystroke handling. CLI maximum RSS is 246.1 → 280.1 MiB; this is peak benchmark-process memory, not installed-app idle memory. Full long-phrase and mixed searches incur context-model overhead, while several English/private-expansion cases improve. Current provisional P95 is 0.089 ms for `shi`, 1.282 ms for the phrase-construction fixture and 0.736 ms for the mixed fixture; dense 64-letter scenarios reach about 15.2 ms. These preview measurements have no captured old-preview baseline. Deferred-edit timing excludes search and UI delivery.

Raw evidence: `before.json`, `final-performance.json`/`.stderr`, `final-previews.json`, `quality-baseline.json`, `quality-final.json`, `final-tests.log`, `data-tests.log` and Debug/Release build logs under `.build/unified-ranking/`. Reproduce current results with the commands in [testing](TESTING.md) and the model guide.

No installation, live host typing, InputMethodKit callback/focus validation, VoiceOver interaction or high-contrast system-setting check was performed for this change. Automated model/UI checks and successful builds do not establish host compatibility or production sentence quality. Earlier checkpoints below describe their then-current, sometimes superseded scoring policies.

## Upstream Chinese weights without authored overrides — 2026-10-20

Chinese generated data now preserves all upstream integer weights and ratios instead of decimal-magnitude score buckets. The 979 original and three local entries retain only spelling/readings; their manual score columns are removed, and unweighted sources cannot overwrite upstream weights. Override corrections may preserve a weight while changing spelling/readings, but cannot assign scores. All 85,596 entries remain. Ten original spellings have no selected upstream frequency and retain unweighted coverage.

The decoder caches a shared continuous `100 + log2(max(1, weight) / maximum_upstream_weight)` scale once during initialization. The one-count floor keeps zero/unweighted calculation finite without altering raw provenance; final scores are logarithmic rather than proportional. Fractional weights propagate through provisional pools, continuation costs and direct presentation. English ranking policies, explicit personal phrases and opt-in learning remain independent. No new dictionary/model was imported and no sentence-context model was added.

With empty learning, both searches rank synthetic `添加过那么多` first, ahead of `添加国那么多`; raw weights are 7,307,184 and 3,063,867. `你说的这个` also ranks first. Upstream priors cannot establish all grammar: `帮我在写` precedes `帮我再写`; the intended longer `帮我再写一个` remains within four choices, and `能想办法优化吗` is third. Nine of the ten everyday sentence fixtures currently rank first; all ten remain within five. The remaining fixture prefers `这个文件明包含英文` over intended `这个文件名包含英文`. These supersede the earlier authored-score first-choice observations. Tests now distinguish source-derived ranking from unchanged learning/selection invariants instead of restoring manual word scores to satisfy former rankings.

All 221 Swift tests (159 core, 31 presentation, 19 settings, 12 storage), 28 vocabulary maintenance tests, both language generation checks and the Debug app build passed. An exhaustive source comparison verified all 85,584 selected upstream weights exactly and the unchanged 85,596 text/reading identities; 12 entries retain unweighted coverage. No installation, process restart or live host-input verification was performed. Existing user phrases and learned preferences were not read, modified or cleared for this change.

## Conservative learning after writing-request investigation — 2026-10-20

Accepting the default with Space no longer creates, reinforces or refreshes a preference, and does not become previous-word context. Deliberate number/mouse choices and navigation followed by Space still train. Chinese single-character preferences remain available for their own full/consumed spelling but no longer transfer into other compositions. The token index and lookup apply this rule consistently on recording, reload, deletion and pruning, including when single-character and word records share a spelling. Multi-character Chinese words and English words retain token ranking, the length-weighted shared 32-point frequency cap, and the existing English-boundary safeguards. No decoder beams, vocabulary, commit text, retention limits or archive schema changed.

Synthetic `ba` → `把` and `xie` → `些` profiles at strengths 1, 8 and 1,000 now preserve first choices `帮我再写` and `帮我再写一个` in Chinese-only/combined-language and provisional/final generation. Standalone `xie` still prefers the learned `些`. Regression coverage also checks explicit whole/prefix overrides and consumed remainders, repeated default acceptance without saved-state changes, context reset, persistence/restart, pause/secure-input/deletion/expiry, multi-character pre-beam learning, normalization, deduplication and canonical Unicode. Positive transfer fixtures now use words rather than characters. The synthetic benchmark's learned-token case now uses `shike` → `食客` repeated three times after `wo` (still 17 letters); previous timing/fingerprint reports for that scenario are not directly comparable.

All 219 tests (157 core, 31 presentation, 19 settings, 12 storage) and the universal Debug build passed. Settings and current documentation explain the policy. Existing archives were neither read nor cleared; old records lack commit-reason provenance, so past default acceptances cannot be selectively removed automatically. Unwanted whole-word/sentence records remain individually manageable. No installation, process restart, live host typing or VoiceOver check was performed. General sentence semantics and the quality of transferring multi-character preferences remain outside this focused safeguard.

## Writing-request ranking investigation — 2026-10-20

With an empty learning profile, both final and provisional searches rank `帮我再写` first for synthetic `bangwozaixie`, and `帮我再写一个` first for `bangwozaixieyige`, in Chinese-only and combined-language configurations. The installed Debug library and the locally built library have matching architecture UUIDs and contain the relevant lexical rows. This checks files on disk, not which library is loaded in the running input method.

Injecting only two synthetic single-word preferences, `ba` → `把` and `xie` → `些`, each at strength 8 without decay, reproduces the screenshot's first two choices: `把那个我在些` and `把你给我在些`. Their base scores are 90.125 and 90.1; token preferences raise them to approximately 103.458 and 103.433. The unlearned `帮我再写` scores 92.225. Internal token weighting can therefore promote an abbreviated `ba` + `n` + `g` path inside `bang`, alongside the preferred homophone `些`. This establishes a reproducible mechanism, not the contents of the user's learning archive. No saved learning data was read or cleared, and no production ranking rule was changed. The user confirmed that pausing learning restores the correct first choice; the archive itself remains uninspected.

The retained regression checks character-by-character entry, both generation stages and their accepted delivery, exact literals and final whole-candidate commit for the two writing examples. All 214 test methods (153 core, 31 presentation, 18 settings, 12 storage), the universal Debug build and whitespace checks passed. Temporary diagnostic printing was removed. No installation, process restart or live host typing was performed.

## Tighter candidate number spacing — 2026-10-20

Candidate text starts five points closer to its number in both layouts, and preferred button widths shrink by the same amount. Synthetic compact light/dark and expanded renders were visually inspected. All 210 tests and the universal Debug build passed. The existing no-stretch layout assertion now allows 0.001 point of floating-point roundoff after AppKit frame conversion; the observed difference was approximately 0.0000000000005 point. Whitespace checks passed. No installation or live host/VoiceOver check was performed.

## Five compact candidates — 2026-10-20

The collapsed strip now shows up to five candidates per page, with number shortcuts 1–5 and five-candidate page steps. Expanded pages still contain nine choices. Selection survives layout switches with its new visible number, and all remaining candidates stay reachable. Focused regressions cover the fifth mouse/number choice, page keys, incomplete last pages, collapse/expansion mapping and narrow bounds. All 210 test methods and the universal Debug app build passed; whitespace checks passed. Synthetic compact and narrow renders were visually inspected. No installation or live host/VoiceOver check was performed.

## Candidate appearance refinement — 2026-10-20

The candidate window now uses a 36-point warm-neutral strip with 28-point buttons, a soft peach selection pill, an orange selected number and adaptive label text. Dark mode uses a matching charcoal/umber palette. Buttons fit their text rather than stretching into retained pending-window width, and text-cell insets are included so normally sized labels do not truncate prematurely. The compact strip replaces long `First N`/source labels with small arrow, pin and text symbols; full descriptions remain in expanded rows, tooltips and accessibility labels. Selection/commit identity, paging, pending interaction guards and input-method registration are unchanged. The system Increased Contrast preference adds stronger outlines, and appearance changes invalidate custom drawing.

Native offscreen light/dark, compact/expanded and narrow renders using curated synthetic candidates were visually inspected. The current workspace passed all 210 test methods (149 core, 31 presentation, 18 settings, 12 storage) and the universal Debug app build. The earlier full-suite run caught eight failed assertions in two concurrently changing English sentence tests; the final complete run passed those tests as well. The UI regression checks cover numbered/mouse identity, exact accessibility prefix descriptions, stale/pending actions, source symbols, narrow bounds and avoiding stretched compact buttons. Whitespace checks passed. This work did not edit the concurrent English decoder/sentence changes, install SI or operate host applications. Live focus, positioning, VoiceOver, actual system Increased Contrast and automatic appearance transitions remain unverified. Named high-contrast appearance construction on this SDK normalizes to Aqua, so it was not treated as a simulation of the system contrast preference.

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

## Automatic prefix confirmation — October 21, 2026

The optional implementation supports both continued-typing and pause-triggered prefix confirmation, with an editable ending. The Typing option defaults to off. Relative-score consensus and exact lexical source/output boundaries are required; this is a conservative heuristic, not a semantic correctness guarantee.

Final-source automated checks:

- `./scripts/test.sh`: passed 272 tests across core, storage, Settings and presentation (12 + 20 + 45 + 195). This includes continued typing with the standard vocabulary, pause timing, single-character pause suppression, editable/exact remainders, ü/u: and separators, near-candidate disagreement, Unicode grapheme boundaries, English safeguards with English disabled, edits/navigation/configuration reset, stale/cross-client/provisional results, and no implicit learning/context.
- `./scripts/build.sh`: Debug universal macOS app build passed with signing disabled.
- `./scripts/benchmark.sh --automatic-confirmation`: Release benchmark and regression gates passed. Six paired workloads retained identical candidate IDs/order, ranking scores and output bytes. All 600 combinations (100 fixed synthetic inputs, two language configurations, three result-delivery patterns) had correct committed prefixes; 133 combinations activated and 467 abstained. Continued typing activated in 58 combinations and a final pause in 83, with overlap. This includes development data and an already inspected historical holdout, so it is not an independent accuracy estimate.
- `git diff --check` and local documentation-link checks passed. Source hashes were unchanged between the final test/build snapshot and benchmark completion.

Paired full-search medians in milliseconds, including evidence extraction when enabled:

| Synthetic input | Without automatic evidence | With automatic evidence |
| --- | ---: | ---: |
| `nihaopengyou` | 20.419 | 21.572 |
| `womenxuexizhongwen` | 36.191 | 39.678 |
| `wojintianxiangqugongzuo` | 15.078 | 16.467 |
| `nihaopengyouxuexizhongwen` | 42.207 | 44.446 |
| `shi` repeated 20 times | 111.362 | 119.329 |
| `MySwiftType` | 7.002 | 7.015 |

Caller-side deferred append p95 was at most 0.018458 ms, and accepted-result delivery/decision p95 at most 0.007333 ms. These regions exclude decoding, panel/marked-text updates, timer scheduling, IPC and host processing. Full-search medians add roughly 5–10% on the measured Pinyin workloads; searches still run on the background worker. The long ambiguous full search remains about 119 ms. This does not establish native key-to-screen latency or a production latency target.

Native verification remains pending. No input method was installed, no enabled input sources were changed, and no input-method process was stopped. Timer delivery, current-client/focus checks, insertion/marked-text behavior, keyboard/VoiceOver Settings access and actual host latency require the automatic-prefix checks in `docs/TESTING.md` on an intentionally installed build. Already committed text uses normal host editing; automatic original-Pinyin reconversion is not implemented.


## Manual Sparkle updates — October 21, 2026

Added a process-lifetime updater shared by Settings and the input menu, pinned to the same Sparkle 2.10.0 framework as Caterm. Verified the installed SDK header: input-menu commands are dispatched to the input controller by `doCommandBySelector:commandDictionary:`, so the menu selector forwards to the app updater rather than relying on a separate NSMenuItem target. Its main-actor bridge retains the existing IMK callback assumption; actual callback delivery still requires native verification.

`./scripts/test.sh` passed all 195 tests in 25 suites, including the pre-existing automatic-confirmation work in this checkout. `python3 -m unittest discover -s Tests/ScriptTests -v` passed all 54 tests. Debug and Release app builds passed with the existing AppIntents metadata-extraction warning. The initial restricted builds/tests could not resolve GitHub or compile SwiftPM's manifest; final successful compiler runs used execution outside that sandbox.

Inspected the Release bundle: the feed resolves to `https://downloads.caterm.com/si/channels/mac/stable-universal.xml`; automatic checks/updates/profile submission are false and pre-extraction signature verification is true. Confirmed Sparkle's notice bytes are bundled. Copied the Release app into a temporary directory under `.build`, re-signed its nested Sparkle helpers/framework and SI app ad hoc using the packaging helper, and passed `codesign --verify --deep --strict`; the temporary copy was then removed. Local-package and publish dry runs with synthetic explicit certificate names passed without real signing, key access or publication. Shell syntax, Python 3.9 grammar, touched-document local links and whitespace checks passed.

No SI process was launched/stopped, no input source or installed app was changed, and no real Keychain update signing, Developer ID signing, Apple notarization or R2 publication was performed. Keyboard/VoiceOver/appearance checks, actual installed update dialogs, signed replacement/relaunch, normal pending-write persistence through that cycle, input-source registration/recovery and representative host typing remain unverified. Existing builds without Sparkle need one manual installation of an updater-enabled release; the new XML feed must be published before checks work.
