# Testing SI

## Segmented marked spelling

`MarkedTextPresentationTests` covers Chinese syllables (`chileme` → `chi le me`),
English words (`iwanttobuild` → `i want to build`), mixed candidates, incomplete
Chinese readings, casing, ü/u: aliases, explicit apostrophes, UTF-16 caret
offsets, prefix remainders, literal commits, and rejected stale results.

On an intentionally installed build, repeat these synthetic inputs in TextEdit
and browser fields. Check Home/End, backward/forward deletion near visual spaces,
candidate navigation, Space/number/mouse confirmation, prefix selection, Return,
shortcuts, Escape and focus changes. Only real source characters should be edited;
Return/shortcuts must preserve spelling without display spaces. Check rapid
typing through provisional/full results, unknown identifiers, disabled languages,
caret positioning near screen edges, light/dark appearance and VoiceOver. These
native host and spoken accessibility checks remain unverified by package tests.

On November 5, 2026, all 443 Swift tests passed with
`./scripts/test.sh --disable-sandbox`, including eight marked-spelling tests,
and the Debug app build passed. The default SwiftPM sandbox could not nest in
the agent sandbox; Xcode required normal compiler/package-cache access. Logs
are local under `.build/segmented-marked-*`. No installation or live host check
was performed.

## HanLP corpus vocabulary review

On November 4–5, 2026, the offline HanLP pass processed all 3,540,828 fragments
and 34,445,051 Han characters in the six existing prepared Chinese subsets,
producing 20,347,213 token occurrences. `hanlp_words.py verify` independently
recounted all token files against exact source text and stored fragment counts.
`check_word_corrections.py` independently verified all eight corrections using
exact, overlapping reference spans, avoiding the model's token-splitting bias.
The [review record](../Data/Vocabulary/Corpus/README.md) retains model/source
hashes, all 463 eligible decisions, 266 additions and eight old/new base weights.

All 38 corpus-tool tests passed. Vocabulary maintenance passed 43 of 44 tests,
including the new addition/readings/evidence and bounded-correction checks. The
remaining failure is the unchanged English domain-count mismatch: metadata
1,209 versus 1,199 CSV rows; both fields/files were compared with HEAD. Both
runtime CSV checks and pinned MSIME context checks passed. An independent
before/after SQLite comparison found exactly 266 added Chinese identities,
eight changed weights, no removals, and a byte-identical English database.

All **435 Swift tests** passed using `./scripts/test.sh --disable-sandbox`
(306 core, 91 presentation, 22 settings, 13 storage and three localization).
The default command was blocked by nested SwiftPM sandboxing. The Debug app
build passed with normal Xcode compiler/package-cache access after the sandboxed
attempt was blocked. Logs are local under `corpus/.cache/`.

`ChineseVocabularyTests.reviewedCorpusTermsRemainSelectableWithExactLiteralAndLanguageFiltering`
checks ordinary/technical and five-/seven-character additions, bilingual and
Chinese-only lookup, exact source/output commits, disabled Chinese and all
languages disabled. Data tests check every added reading against the maintained
character inventory and preserve all earlier category weights outside the
explicit reviewed exception. No input method was installed or operated in a
live host. On an intentionally installed build, check synthetic `chunyou`,
`kongliebiao`, `kechixufazhan` and `fujian` in TextEdit and a browser, including
candidate selection, prefix remainders, Return, Escape, shortcuts and focus
changes. These checks do not establish representative ranking quality.

## Restored English article

On November 4, 2026, `english/common.csv` restores the indefinite article `a`
at the standard local editorial weight 10, independently of upstream conversion.
`EnglishArticleTests` covers exact lowercase/uppercase lookup, continuous and
apostrophe-delimited `send a english` segmentation, enabled-language filtering
and exact literal fallback. Offline inspection with empty personal state confirms
that `sendaenglish` now generates `send a english`; it ranks 33rd in the full
merged list and remains outside the current candidate-window shortlist.

All 434 Swift tests and the Debug app build passed. Both CSV dictionary checks
and the pinned MSIME context check passed. Of 42 vocabulary-tool tests, 41 passed;
the existing domain-count mismatch remains (metadata 1,209 versus 1,199 rows).
Logs are under `.build/english-article-*`. No installation or live host verification
was performed. On an intentionally installed build, check synthetic `a`, `A`,
`sendaenglish` and `send'a'english` in TextEdit and a browser, including selection,
Return, Escape, shortcuts, focus changes and disabled English.

## English dictionary-token cost

On November 4, 2026, each English dictionary token gained an additional
three-nat cost; Chinese single-character tokens retain their two-nat cost.
The addition is per lexical token, including single-letter words, exact lookup,
completions, consumed prefixes and English/mixed sentence edges. Personal-code
priors and unrecognized verbatim costs are unchanged. With empty personal state,
both preview and full search place `么` above English `me`, and `麼` above
`men` for input `me`. Bilingual `man` now leads with `慢`, while the exact English
word remains available. Lower-scoring English completions can fall outside the
window's ordinary budget; the full engine retains them without reserving slots.

All 432 Swift tests passed (303 core, 91 presentation, 22 settings, 13 storage
and three localization), and the Debug app built successfully. SwiftPM and Xcode
required normal compiler/cache access after the agent sandbox blocked manifest
compilation and dependency resolution. Logs are under `.build/english-word-penalty-*`.
No installation or live host verification was performed. On an intentionally
installed build, check `me`, `man`, `iwanttobuild` and `woxiangyaodeploy` in TextEdit
and a browser, including number/mouse selection, prefix remainders, Return,
Escape, shortcuts, focus changes and enabled-language changes.

## Yuliao editorial weight adjustment

On November 4, 2026, `语料` (`yu'liao`) increased from 1,953 to 2,500.
Offline `SICandidateExport` with empty personal state confirmed `yuliao` ranks
`预料`, `语料`, `语聊`, `玉料`, `鱼疗`, `余料`, with exact literal input retained.
Both CSV dictionary checks, pinned MSIME context checks and ranking checks passed.
All 430 Swift tests and the Debug app build passed with normal compiler/cache
access after sandboxed attempts failed. Of 42 vocabulary-tool tests, 41 passed;
the unrelated English domain-count assertion failed (metadata 1,209 versus 1,199
rows). No input method was installed and no live host checks were performed.


## Input-menu language switches

Run `./scripts/test.sh` and `./scripts/build.sh`. `LanguageSettingsTests` covers independent language persistence, configuration invalidation, unchanged direct-input rules and recording consent. `DeferredCandidateTests.languageChangesKeepCompositionAndCaretWhileRejectingOldCandidates` covers language changes through English-only, neither, Chinese-only and both, retaining exact input/caret, rejecting obsolete preview/final results and restoring ambiguous bilingual candidates.

On an intentionally installed build, select SI and open the macOS input-source menu. Check that English and Chinese (Simplified) reflect Settings, toggle independently, persist after a normal restart and have no keyboard shortcuts. With both enabled, `he` must retain English and Chinese choices; with neither enabled, exact original spelling must remain available. During composition, move the caret and toggle a language: preserve marked spelling/caret, refresh choices, and prevent an old candidate click or automatic-confirmation timer from committing a stale choice. Repeat in TextEdit, a browser field, an editor and Terminal, including focus changes and host shortcuts. In an app with direct input enabled, language checkmarks must not override passthrough; disable that app rule in Settings before testing conversion. Check menu keyboard navigation, VoiceOver checkmark announcements and English/Chinese UI labels in light/dark appearance. Automated tests/builds do not establish native menu routing or host compatibility; these checks require a login-session verification.

On November 3, 2026, all 444 Swift tests and the Debug app build passed. The initial sandboxed commands could not access SwiftPM/compiler facilities; both required commands passed with ordinary cache access outside the agent sandbox. No installation or live menu, host-app, keyboard or VoiceOver verification was performed.

## Matched-input coverage ranking

On October 31, 2026, the user authorized a soft coverage reward after comparing
Rime, libime and libpinyin candidate presentation. The shared merge now adds five
points per consumed source letter/digit to the lexical/preferences score. It does
not estimate a suffix conversion, add a confirmation cost, discount prefix
learning or make length an absolute priority. The existing 20/2 insertion costs
and 1.05 frequency coefficient remain unchanged. Separators and punctuation earn
nothing; ü/v/u: aliases count equally. Output length and lexical-unit count earn
nothing. Candidates containing verbatim spans receive no coverage reward.

The user then requested restoring the presentation limit: only the first four
ranked choices may include constructed hypotheses, followed by single-character/
word choices within the ordinary 27-choice budget. Extra dictionary-character
paging and exact literal retention remain. The five-point coverage reward is
unchanged, so continuous sentences can still lead while their extra alternatives
stay out of later word-selection pages. Languages share this same restriction.

`InputCoverageRankingTests` covers continuous Chinese/English first choices,
preview/full agreement on those examples, whole-input default commits, selectable
mixed sentences, equal reward across lexical splits/completions, spelling aliases,
separators, punctuation and verbatim/literal exclusions. Existing prefix tests
also inspect coverage-adjusted scores across changed whole paths and unknown or
long tails without querying suffix providers; consumed-only learning, exact
Unicode boundaries and editable remainders remain covered. The presentation tests
render continuous sentences in compact/expanded light/dark views, inspect their
accessibility labels and verify first-cell number/mouse identities and commits.
The long-composition regression keeps at least six full hypotheses in the engine,
shows only its leading four, checks that all later nonliteral choices are single
lexical units, and confirms a later word by number/mouse identity while leaving
its exact remaining spelling editable.

Run `./scripts/test.sh`, `./scripts/build.sh` and
`./scripts/benchmark.sh --quality`. The coverage coefficient is a heuristic tuned
on authored development/regression fixtures, including the previously inspected
historical holdout; these results are not independent accuracy estimates.

The previous unrestricted-window run passed 409 tests and retained all 86
authored quality targets in the window, with 78 first and 85 within five. Its
`.build/coverage-*` report predates the restored four-hypothesis limit and is
historical. The coefficient and engine ranking are unchanged.

After restoring the four-hypothesis policy, all 410 Swift tests passed (295 core,
90 presentation, 15 settings, seven storage and three localization) with
`./scripts/test.sh --disable-sandbox`; the Debug app built successfully. SwiftPM
uses the flag for the execution environment's manifest sandbox limitation, and
Xcode requires normal compiler/package-cache access. The new long-composition
regression verifies both search stages and compact/expanded number/mouse word
selection after the four leading full sentences. Logs are under
`.build/four-hypotheses-*`. The updated Release quality report has 78/86
authored targets first, 86/86 within five, 86/86 retained in the window and
86/86 retained in the engine. Preview/full first choices agree on all
86 examples. These are inspected development/regression fixtures, not an
independent accuracy estimate. No installation or live host verification was performed.

On an intentionally installed build, use synthetic `mingtianwomenqubeijing`,
`ming'tian'wo'men'qu'bei'jing`, `iwanttobuild`, `woxiangyaodeploy`,
`ci'chuxian'de` and `lu:'se'world` in TextEdit and a browser. Check continuous
composition and Space, first/nonfirst number and mouse confirmation, four leading
hypotheses followed by word/character choices, editable prefix remainders, Return,
Escape, shortcuts, focus changes and disabled languages. Repeat compact/expanded and light/dark
checks with VoiceOver. No installation or live host verification is implied by
the automated checks.

## DMG filesystem sizing

On October 31, 2026, macOS 27.0.1 reproduced the release failure with an approximately 89 MiB SI installer and 132 GiB available on the host: default `hdiutil create -srcfolder` failed copying `Install SI.pkg` into the image with `No space left on device`. The identical contents succeeded with explicit HFS+ and with an explicitly enlarged 256 MiB APFS image. Packaging now selects HFS+ while retaining compressed UDZO output and compatibility with older supported macOS releases.

All 54 script tests and 289 shared-core tests passed, as did Debug/Release app builds and the arm64 packaging dry run. A complete local ad hoc arm64 package succeeded; `hdiutil verify` and SHA-256 passed. Read-only mounting confirmed HFS+, the expected package/instructions/license and matching license bytes. Installer queries returned `RequireLogout` and only `CurrentUserHomeDirectory`; expanding the package confirmed an arm64 payload and strict nested app signature. The image was detached afterward. No SI installation, launch, version increment, commit, notarization or publication occurred. Developer ID signing/notarization and host compatibility were not reverified for this packaging-only change.

## Editorial weight for 上次

On October 31, the user requested a higher dictionary weight for `上次`
(`shang'ci`). Its base CSV weight changes from 21,766 to 40,000, adding
`1.05 * log2(40000 / 21766)`, about 0.922 bits, to a lexical use of this word.
The 20/2 insertion costs and 1.05 frequency coefficient are unchanged.

The Chinese dictionary was regenerated with `csv_dictionary.py build --language
chinese`. A complete comparison of all 2,141,202 runtime rows confirms that only
this weight changes; text, reading, row ID and every other row remain identical.
The focused regression checks the packaged weight, score gain relative to the
former weight, direct/prefix consistency, explicit separators, bilingual and
Chinese-only settings, preview/full search and literal retention. Existing
`heshangcibi` complete-conversion and commit coverage passes.

All 402 Swift tests passed (289 core, 88 presentation, 15 settings, seven storage
and three localization), and the Debug app built. The Chinese dictionary and
pinned context checks pass. Of 42 Python vocabulary tests, 41 pass; the existing
English domain edit leaves 1,199 rows while metadata still records 1,209. The
two-language dictionary check likewise reports that the English resource is stale;
this task does not regenerate or change those unrelated English files. Logs and
the exact database comparison are under `.build/shangci-weight-*`.

The [editorial adjustment record](../Data/Vocabulary/chinese/README.md#si-editorial-weight-adjustments)
distinguishes this value from the pinned upstream import and explains reimport
behavior. No input method was installed or launched. Native TextEdit/browser,
selection, prefix remainders, Return, Escape, shortcut and focus checks remain
unverified; repeat them with synthetic `shangci`, `shang'cibi` and `heshangcibi`
on an intentionally installed build.

## Restored insertion costs

On October 31, the user requested restoring the per-word insertion cost to 20
nats and the extra Chinese single-character cost to two nats after the 19.5/1.75
and temporary 10/1 experiments. The frequency coefficient remains 1.05. The
earlier experimental reports below retain their historical parameters and are
not measurements of the restored configuration or the current prefix policy.

Independent lexical/exhaustive-search score fixtures use the restored constants.
The synthetic frequency-boundary regression checks that increasing the middle
word's weight can overcome one additional word and two single-character costs,
while both alternatives remain available in preview/full search and in either
dictionary insertion order. The reported `heshangcibi` regression still retains
`和上次比` as the leading complete conversion with the 1.05 coefficient;
consumed-only prefixes keep their independent ordering contract.

`./scripts/test.sh` passed all 401 tests (288 core, 88 presentation, 15 settings,
seven storage and three localization), and `./scripts/build.sh` built the Debug
app. Logs are `.build/restore-20-2-tests.log` and
`.build/restore-20-2-debug-build.log`. No input method was installed or launched;
native host behavior remains unverified. On an intentionally installed build,
repeat the synthetic host checks below with `heshangcibi`, `danci`, `nihao` and
`mingtianwomenqubeijing`, including explicit candidate/prefix selection, default
Space, Return, Escape, shortcuts and focus changes.

## Consumed-only prefix ranking

Prefix scores now depend only on the spelling actually consumed. Suffix
conversions, whole-path support, unknown-remainder byte costs, additional
confirmation costs and total-input learning discounts have been removed.
Short prefixes may lead complete sentences. Historical first-choice/window
counts below predate this policy; complete-sentence quality fixtures now compare
complete candidates separately and do not promise those candidates a window slot.

Run `./scripts/test.sh --filter 'CompositionCoverageTests|PrefixLearningTests|PrefixConfirmationTests|HomophonePrefixSelectionTests|WholeWordCandidateTests'`,
then the full tests and `./scripts/build.sh`.
`CompositionCoverageTests` verifies unchanged prefix scores with weak/strong
whole candidates, unknown and long tails, no suffix provider queries, exact
Unicode bytes, aliases/separators, raw fractional scores and consumed-only
learning. `PrefixLearningTests` checks full capped prefix bonuses across different
remaining spellings and lengths. `HomophonePrefixSelectionTests` covers both
languages, provisional/final results and the font-filtered expanded window:
`词` remains before `慈`; selecting `词` then `出现的` commits exactly `词出现的`.
Default-acceptance fixtures commit whichever candidate leads, consuming only its
source span and preserving any remainder. Whole candidates have no priority.

For native verification on an intentionally installed build, use TextEdit and a
browser with Chinese alone and both languages. Type `cichuxiande`,
`ci'chuxian'de`, `ci'nihao`, `ci'hello`, `dayin`, `nihaopengyou` and
`iwanttobuild`. Compare the `词` prefix score/order under different tails; choose
prefixes by number and mouse, then confirm the remainder. Check default Space,
Return, Escape, shortcuts, focus changes and VoiceOver. This change does not
install or launch SI; live host routing remains unverified.

On October 31, 2026, all 401 Swift tests passed (288 core, 88 presentation,
15 settings, seven storage and three localization) with
`./scripts/test.sh --disable-sandbox`; the Debug build passed. The flag avoids
the execution environment's SwiftPM manifest sandbox restriction, and Xcode used
its normal compiler/package caches. No installation or native host/VoiceOver
verification was performed.

The synthetic Release quality report retains all 86 complete targets in the
engine; 80 rank first and all 86 rank within five when comparing complete
candidates only. With prefixes included, three targets rank first, 26 rank within
five and 39 remain in the window shortlist. Preview/full first choices agree on
all 86 cases. This is a substantial change in presentation: short prefixes can
push complete targets out of the window under the unchanged four-leading-choice
rule. These fixed fixtures are not independent accuracy data. Logs and the
report are in `.build/prefix-consumed-only-*`.

## Category filenames and local weight defaults

The November 5 phrase/verse split adds flat Chinese CSV discovery under
`Data/Vocabulary/chinese/phrase/`. The compiler regression moves base and imported
rows across directories while preserving a zero authoritative base weight,
upstream-over-local precedence, generated row IDs and English isolation.
The full effective dictionary and compiled SQLite rows are independently
compared with the pre-split dictionary. Run the vocabulary-tool tests and
`python3 scripts/csv_dictionary.py build --check --language chinese` after
editing either Chinese source directory. This is source organization; it
requires no input-method installation or host-event behavior change.

The ten imported Chinese categories now use their upstream stems directly
(`diming.csv`, `shici.csv`, etc.). Metadata tracks ownership and precedence;
conversion retires the former prefixed paths only when their recorded bytes
match, protecting local edits. Base and imported CSV contents/weights are
unchanged by this rename.

All nine currently present local categories (seven Chinese, two English) retain
their exact text/reading sequence with every stored weight set to 10. The prior
independent deletion of `culture_sports.csv` is preserved. The compiler uses 10
for a blank local weight, while base/imported weights remain mandatory and an
explicit zero remains zero. New Radar domains use that same default. The tests
cover both languages, protected upstream weights, rename/retirement behavior,
all checked-in local rows and new-domain defaults.

Run `python3 -m unittest discover -s Tests/VocabularyTests -v`, the locked
conversion check, CSV/context resource checks, `./scripts/test.sh` and
`./scripts/build.sh`. Local category weights can change ranking; this does not
retune the engine or the independently pinned language models. No input method
installation or live host verification is part of this maintenance change.

On October 29, 2026, all 42 vocabulary-maintenance tests, all 405 Swift tests,
the Debug build, locked conversion reproduction, both dictionary checks and the
pinned Chinese context check passed. Source/base CSV hashes matched their
pre-rename contents; all nine local text/reading sequences matched their
pre-normalization sequences. Documentation links and `git diff --check` passed.

## Thailand homophone ranking

`ChineseFrequencyRankingTests.thailandRanksAheadOfHomophone` checks that
`泰国` ranks ahead of `太过` for `taiguo` and `tai'guo` in provisional and
full results, with Chinese alone and with both languages enabled.

On November 6, 2026, both generated dictionaries and the pinned MSIME context
passed verification. All 444 Swift tests and the Debug app build passed.
Vocabulary tooling passed 44 of 45 tests, with the existing domain row-count
mismatch. Live host verification is pending. In TextEdit and a browser field,
use an installed build with empty personal preferences for this spelling and
check that `泰国` appears ahead of `太过`, then confirm each candidate.

## Wanxiang base and category replacement

`scripts/wanxiang_dictionary.py` imports pinned `rime-wanxiang-data` revision
`adfa047c339627737f0a4c75674a8042c1ef7f72`. Chinese `zi`/`jichu`/`duoyin`
share base; ten other normal dictionaries retain separate `wanxiang_*.csv`
categories. English `en` supplies its base. The ten preexisting category CSVs
remain byte-for-byte unchanged. Base weights take precedence, followed by
imported category weights and preserved local supplements. Both packaged
resources reject the retired relative-frequency unit.

Run the import reproduction and resource checks documented in
[the conversion guide](../Data/Vocabulary/Wanxiang/README.md), followed by the
full vocabulary tests, `./scripts/test.sh` and `./scripts/build.sh`.
`test_wanxiang_dictionary.py` covers source checksums, exact weights, tone/ü
conversion, missing/malformed weights, casing collisions, classified imports,
unchanged local categories, retirement with local-edit protection, offline
conversion, read-only checks and publication rollback. `DictionaryDatabaseTests`
checks the new unit and exact `but`/`不` weights, plus rejection of old resources.

Dataset-specific fixtures now use Wanxiang weights/casing. The independent
Chinese arithmetic cases are `距离/特别远`, `帮我/在写`, `你好朋友` and
`能/想办法/优化/吗`, computed separately from the SQL rows and MSNG binaries.
The one-letter rendering fixture injects its own candidate, since source English
does not include `a`. Mixed spacing still checks multiple English words, exact
prefix boundaries and commits. Automatic-confirmation positives use explicit
boundaries where the newly imported English word `peng` would conservatively
block an unseparated tail; a separate regression checks that protection.
No scoring, language-transition, beam or automatic-confirmation rules were
retuned for the dictionary update.

On October 29, 2026, all 405 Swift tests, 39 vocabulary-maintenance tests,
conversion/resource/context checks and the final Debug build passed. Full scope
and limits are in the [conversion verification record](../Data/Vocabulary/Wanxiang/VERIFICATION.md). No input method was
installed or restarted. Live host positioning, focus changes, shortcuts,
selection and spoken VoiceOver remain unverified. On an intentionally installed
build, exercise synthetic Chinese/English/mixed input in TextEdit and a browser,
including `but`, `bu`, `gmail`, `ma`, apostrophe/ü aliases, numbered/mouse choices,
prefix remainders, Return/Escape, focus changes and automatic-confirmation
English-tail protection. Do not treat source equality as Wanxiang/Rime runtime
parity or a ranking-quality improvement.

## Candidate widths follow visible text

`CandidateViewTests.expandedColumnsGrowForLowerRowWordsAndPrefixIndicators`
checks that a longer word or prefix in a lower row widens its shared column and
the expanded window. Full candidate text, numbers and source hints fit at the
natural size, including words wider than the former 280-point cell cap. Compact
cells also use their full measured width. Collapse restores the compact size;
mouse identity, active-row numbering and complete accessibility text stay intact.
At a 340-point screen constraint, columns remain aligned and within the card;
clipped text stays complete in tooltips and accessibility labels.

`CandidateViewTests.bufenciExpandedCandidatesHaveRoomForTextAndSourceIndicators`
checks every visible candidate in the reported composition, including `卟吩`,
which previously appeared as an ellipsis under the first row's narrower column.
Set `SI_WIDTH_SNAPSHOT_PATH=/tmp/si-candidate-width` while running
`./scripts/test.sh --filter CandidateViewTests` to save light/dark regular,
narrow and `bufenci` previews. On an intentionally installed build, repeat the
composition in TextEdit and a browser field, expand/collapse and page candidates,
then check Space, digits, mouse, shortcuts, focus changes, narrow screens and
VoiceOver. Offscreen renders and accessibility-label checks do not establish
live host positioning or spoken VoiceOver behavior.

On October 29, 2026, all 404 Swift tests and the Debug app build passed. The
`bufenci`, long-word and narrow-screen light/dark renders were inspected. No input
method was installed; live host and spoken VoiceOver checks remain unverified.

## Mixed candidates without a display reservation

`ChineseSentenceAlternativesTests.mixedChoicesCompeteForTheRankedHeadWithoutAReservation`
checks that both exact mixed results and mixed completions need a position in the
first four ranked choices; a lower-scoring mixed result cannot displace a higher
Chinese sentence. Single-language reachability and exact literal input remain
protected. The Chinese decoder still emits six base terminal sentences; the
window does not add lower-ranked sentences to fill unused hypothesis slots.

`UnifiedRankingPresentationTests.bufenciMixedCompletionNeedsItsScoreToReachTheRankedHead`
checks provisional/full delivery and compact/expanded selection. With both
languages enabled and no learned preferences, `bufenci` retains `部分 city` in
the engine but omits it from the window; the first four visible choices are
`部分次`, `部分此`, `部分词`, `部分刺`. With `bufencity`, the exact mixed result
qualifies by score and commits its exact source/text. Run these two suites plus
`FirstWordPrefixTests`, `CandidateSelectionTests` and `SequentialWordSelectionTests`.
On an intentionally installed build, repeat both inputs in TextEdit and a browser
field, checking Space, numbered/mouse selection, editing, shortcuts, focus changes
and VoiceOver. These live host checks remain unverified.

On October 29, 2026, all 402 Swift tests and the Debug app build passed after
removing the mixed display reservation. No input method was installed.

## Requested Chinese vocabulary addition

`ChineseVocabularyTests.requestedAlchemyPhraseIsACompleteDictionaryCandidate`
checks `lianxiandan` and `lian'xian'dan` → `炼仙丹` in provisional/full results,
with Chinese alone and both languages enabled, plus exact candidate commits,
literal preservation and English-only filtering. On October 28, 2026, all 400
Swift tests and 22 vocabulary-maintenance tests passed; both CSV dictionaries,
the pinned Chinese context resources and the Debug app build passed validation.
A before/after SQLite comparison found exactly this one added text/reading/weight
row and no changes to existing entries. No input method was installed. On an
intentionally installed build, verify selection in TextEdit and a browser field;
native host compatibility remains unverified.

## Prefix confirmation ranking

`./scripts/test.sh --filter 'PrefixConfirmationTests|CompositionCoverageTests|PrefixLearningTests|CandidateScoringTests'`
checks that whole choices and prefixes compete using their own consumed-spelling
scores in provisional/full results and the shortlist. For `dayin`, `打印`, the
English `day in` conversion and the `day`/`day I` prefix choices remain engine
alternatives. Prefixes have no extra confirmation charge and can rank first.
Selecting a prefix must consume only its exact source span and keep the rest
editable. Return and shortcuts preserve the exact pending spelling.

The October 28 eight-bit confirmation-cost calibration is superseded by the
October 31 consumed-only policy; its former first-choice counts do not validate
current window ordering. See [current verification](#consumed-only-prefix-ranking)
for the test scope and native checks.

## Chinese context with unknown sentence position

Run `./scripts/test.sh --disable-sandbox --filter ChineseCompositionContextTests`.
The regressions check `shihou` and `shi'hou` in Chinese-only and bilingual
provisional/full requests: with empty learning, `时候` leads `事后` by dictionary
frequency. Prefix confirmation and English-to-Chinese boundaries must not add
sentence-opening evidence. Constructed candidates retain word spacing and language-transition costs without corpus evidence.
The existing independent arithmetic fixtures exclude corpus sentence-opening
increments while retaining word, spelling and language-transition costs.

On October 28, 2026, `./scripts/test.sh --disable-sandbox` passed all 387 Swift
tests (279 core, 83 presentation, 15 settings, 7 storage and 3 localization), and
`./scripts/build.sh` completed the Debug app build. No input method was installed.
Native host behavior remains unverified for this change.

On an intentionally installed build, use synthetic text in TextEdit and a
browser. Enter `shihou` at the start and middle of a sentence with app vocabulary
disabled; verify `时候` leads in both cases. Repeat after choosing a prefix and
after an English word, check provisional/final refresh, exact spelling via Return,
candidate confirmation, shortcuts and focus changes. The engine does not inspect
surrounding host text or claim to detect actual sentence boundaries.

## Dictionary-only runtime ranking

Run `./scripts/test.sh` and `./scripts/build.sh`. `CandidateScoringTests` checks
shared lexical costs across languages. `ChineseCompositionContextTests` checks
dictionary frequency, independent prefix remainders and sentence arithmetic.
`CompositionCoverageTests` and `MixedEnglishSpacingTests` check exact continuation
boundaries, language transitions and word spacing. Builds need no model staging.

On an intentionally installed build, use synthetic text in TextEdit and a browser:
check `shihou`, `iwanttobuild`, `heishere`, `nihaoworld` and `woxiangyaodeploy` with
Chinese-only, English-only and bilingual settings. Check provisional/full refresh,
Space, numbers, mouse selection, prefix remainders, Return, Escape, caret edits,
shortcuts, focus changes and app-vocabulary pause/clear. Context-sensitive ordering
can differ from earlier builds. Verify automatic confirmation on ambiguous input.
Live host behavior and VoiceOver require manual verification.

## Offline English conversation acquisition

On November 4, 2026, the selected English conversation collection acquired and
verified 833,930,152 pinned raw bytes across ConvAI2, BST, Topical-Chat,
Taskmaster 1/2/3, ABCD, SGD and OASST1. The frozen ConvAI2/BST archive hashes
match the publisher download manifests; Topical-Chat's five original files
also match the pinned publisher Git blob identities. Full data terms and
publisher notices are retained separately from downloaded data. No external
reading-set retrieval, model training, app installation or private SI data
access was performed.

The complete `corpus/english/prepared/dialogue-v1/` bundle contains 118,297
dialogue/tree records, 2,262,970 utterances and 138,666,423 Unicode code points.
The independent full verifier agrees with the tracked [English snapshot](../corpus/english/snapshot.json).
Two full preparations produced byte-identical output across all 48 bundle
files, including manifests and copied attribution. Raw and prepared data stay
ignored by Git; only source pins, attribution, code/tests, docs and the measured
summary are tracked. See [the English guide](../corpus/english/README.md).

Source inspection found 8,939 duplicate ConvAI2 second-speaker presentations,
which preparation excludes while preserving the complete original view. BST
starter/context/suggestion fields, Topical-Chat reading sets, ABCD action
records and SGD API/schema fields are not prepared as utterances. Empty/control
turn exclusions are counted without rewriting retained text. Taskmaster has
reused IDs: nine identical selected records are excluded, distinct transcript
variants retain shared grouping IDs with unique record identities, and 55
missing speaker labels are explicitly `unknown` rather than inferred.

Taskmaster-3's model-example TSVs reuse 21,894 complete dialogue IDs across
multiple splits; another 788 source dialogues have no TSV examples. These
complete dialogues remain explicitly `unsplit`, with the original example-split
memberships retained. No clean dialogue-level train/test separation is claimed
for those TSVs. Original boundaries elsewhere, including Topical-Chat's
frequent/rare sets and OASST1's Parquet splits, are retained. OASST1 keeps
original parent edges for filtered English message trees; serialization order
must not be treated as conversational adjacency. This acquisition is not a
ready-to-train mixture or a general partial-copy/cross-source overlap audit.

All 31 corpus tests (19 existing Chinese and 12 new English regressions), all
301 current Swift tests and the Debug app build passed. The English regressions
cover all seven readers, exact text, field selection, original/unassigned
splits, overlapping example-split evidence, reused IDs, graph edges, checksum
failure, traversal rejection, frozen attribution, immutable outputs and failed
preparation rollback. Restricted Swift/Xcode attempts failed on compiler/cache
sandbox access; authorized reruns passed. No native host compatibility or
model-quality result is implied by these offline checks.

## Offline Chinese corpus preparation

The subsequent October 30 Wikipedia addition resolved the latest complete official Chinese article dump to `20261001`, requiring both article generation and combined-file jobs to be done and agreement between completion metadata, SHA-1 list and HTTP file size. The full 3,430,912,430-byte raw archive passed official SHA-1 `04d5eec3c249fdf8604b97f4435e019c60a4ec94` and local SHA-256 `5db9052efe9ca97aa3da05ffe5b2f12c8ffe5e040f0a9d1ced82ec2fda5d7e2f`. Slow official/Your.org transfers resumed from retained ranges through the Wikimedia-listed Umeå University mirror, with at most three concurrent connections. Initial text preparation produced 942,413 fragments and 9,999,995 Han characters; this is a character-limited subset of the full raw dump. The [Wikipedia snapshot](../corpus/chinese/wikipedia-20261001.snapshot.json) records exact hashes/counts. The new bundle passed text/length/hash/origin/license/metadata checks, all six pinned raw archives passed verification, and the original five-source bundle still passed against its frozen source lock after Wikipedia was added. All 19 corpus tests, 287 Swift tests and the Debug build passed. Corpus tests cover completed-date selection, combined-file readiness, unchanged other pins, mirror provenance, safe range resumption/assembly, corruption rejection, namespace/redirect filtering, nested wikitext and exact page/revision origins. No training or app installation was performed.

On October 30, 2026, the new [corpus workspace](../corpus/README.md) downloaded and SHA-256-verified five pinned archives: LCCC-base training, Chinese mC4 shard 0, and Kubernetes/TensorFlow/MDN documentation. The bounded initial preparation produced 2,598,415 within-source-unique fragments containing 24,445,056 Han characters. LCCC/mC4 each stop just below ten million unique output characters; the three documentation selections are complete. Two preparation runs produced byte-identical text and aligned origin files for all five sources. `corpus/check.py` passed source/output/license hashes, Han/length validation and text/origin/count alignment; the retained [snapshot](../corpus/chinese/snapshot.json) records exact results. The lexical export passed every source/output hash, deterministic ordering, syllable/character alignment, count and copied-attribution check: 49,354 character/readings, 2,091,723 word/readings and 125 excluded entries.

All ten synthetic corpus regressions, all 287 current Swift tests and the Debug app build passed. Initial restricted Swift/Xcode attempts could not access compiler sandbox/cache/network services; normal-permission reruns passed. No app behavior changed, so no native host, input-source installation, VoiceOver or model-quality check was performed. Data preparation assigns no training splits, labels no sentence Pinyin and starts no model training. Raw/prepared corpora and the isolated OpenCC environment are ignored by Git; pinned source notices, scripts and measured snapshots are retained.

To repeat the corpus checks, use `corpus/.venv/bin/python -m unittest discover -s corpus/tests -v`, `python3 corpus/fetch.py all --check`, and `corpus/.venv/bin/python corpus/check.py --bundle corpus/chinese/prepared/chinese-v1`. Use a new output path for another preparation run. The corpus guide documents environment setup, acquisition, limits and complete-pinned-subset preparation.

## Offline model training framework

On October 31, 2026, the constructed Chinese ranking challenge froze 1,230 cases from 337 anchors and 171 connected spelling/contrast families, split into 299 development and 931 test cases. All 197 candidate snapshots reproduced exactly through the new offline `SICandidateExport` target, which uses the app's shared core and preserves eligible engine order and language-aware identities. The exact normalized context-plus-reference audit found no matches in 1,438,402 prepared public documents across train/validation/test; this does not rule out semantic overlap or imply independent human annotation. All 24 small-framework tests, 287 Swift tests and the Debug app build passed. Coverage includes shared-contrast family isolation, maintained Pinyin alignment, document-local overlap matching, missing/empty pools, real-checkpoint scoring, abstention, file corruption and audit/model dataset mismatches. The exporter also built in Release. Trained model root-module hashes/code identity stayed unchanged, and no weights were modified.

The frozen development split completed with the user's existing step-10,000 checkpoint on MPS. On its 83 real-decoder cases, top-1 changed from 33/83 in the first eligible engine order to 44/83 after LM scoring; 15 baseline errors became correct and four correct choices became wrong, with gold available for 81/83 pools. On 83 controlled cases, top-1 changed from 50/83 in synthetic pool order to 57/83. These are initial development results on authored labels, not production quality estimates. No test-split model evaluation or input-method installation was performed. Reports are ignored; verification logs are under `/private/tmp/si-challenge-*`. See the [challenge guide](../llm/reranker_small/benchmarks/README.md) for commands, protocols, limitations and test use.

The [small reranker guide](../llm/reranker_small/README.md) documents independent setup, preparation, training, resume, evaluation, scoring and export commands. On October 30, 2026, all 19 small-framework tests, 19 corpus tests, 41 converter tests, 287 Swift tests and the Debug app build passed. Coverage includes whole-document retention, conversation/page grouping, train-only vocabulary, paragraph-overlap rejection, corruption checks, token-weighted accumulation, CPU bitwise resume through epoch rollover, candidate first-token scoring, Unicode boundaries, stable ties, missing-gold recall and inference-only export. Tiny synthetic CPU workflows exercised preparation through export; MPS checks covered a full 7,419,392-parameter 256-token backward pass and tiny-model learning/resume. MPS repeat/resume weights satisfy `atol=1e-6, rtol=1e-5` with exact RNG/cursor checks; repeated fresh MPS runs also showed sub-micro floating-point variation. These checks do not establish candidate quality or host latency.

A separate preparation-only check read all six pinned public raw sources with a 50,000-character soft budget per source. Its 3,748 retained documents included 98 with paragraph breaks and a longest document of 22,694 characters. Formal dataset/run directories were not created, and no formal small-baseline training, input-method installation or native integration was performed. Run `./llm/reranker_small/scripts/check.sh` and `./llm/reranker_small/scripts/smoke.sh --output NEW_DIRECTORY` to repeat the synthetic checks. Temporary verification logs are under `/private/tmp/si-small-reranker-*` and `/private/tmp/si-reranker-*`.

On October 30, 2026, the model workspace was organized into `reranker_small/`, `reranker_large/` and `pinyin_to_text/`. At that initial organization step only the converter had an implementation and weights. All 12 original converter Python modules remained byte-identical, preserving the code-identity calculation; 126 source/config/prepared/checkpoint/report files passed before/after SHA-256 checks. Existing prepared bundles, checkpoints and historical report metadata were relocated without rewriting their contents. The shared virtual environment stayed at `llm/.venv`. Both model-specific and legacy script paths, the workspace Make delegate and direct model Make target resolved the existing 19,711,488-parameter config. All 41 converter-framework tests passed, including a checkpoint created via the legacy namespace and resumed via the model-specific namespace, plus old script execution from another working directory. An existing relocated checkpoint loaded successfully for the synthetic input `nihao`. All 287 Swift tests and the Debug app build passed. No formal training, model download, input-method installation or native host verification was performed.

On October 28, 2026, the default changed to the 19,711,488-parameter Pinyin-only model and six maintained character/word CSVs (2,021 train, 73 validation, 69 test pairs). Tests freeze the full focused collection with the real small-model limits, check lossless encodings/no truncation, retain homophones and verify Chinese lexical-only sources and matching independent shell presets. The old 0.403B parameter-count regression remains. All 39 framework tests, the focused full-source four-step tiny CPU smoke, 383 Swift tests and the Debug build passed. A bounded MPS probe used the actual 19.7M config and full training vocabulary, repeating eight authored training pairs: top-1 memorization was 8/8 at both 40 and 120 updates. It saved no checkpoint and did not train the full corpus. This dataset's held-out coverage includes unseen output characters (22/73 validation and 19/69 test rows initially), so preparation and tiny memorization success do not establish held-out conversion quality. No formal default run was started.

On October 27, 2026, a nonzero-dropout gradient comparison exposed an MPS activation-checkpoint RNG defect in the pinned PyTorch 2.6 path. With dropout 0.1, ordinary/checkpointed forward logits and loss matched exactly, but the maximum gradient difference was 0.134271 and backward advanced MPS RNG. The new MPS regression failed before the fix. Explicit per-layer RNG replay reduced the same probe's maximum gradient difference to 7.45e-9; CPU gradients matched exactly. Both CPU/MPS regressions pass with retained-graph repeated backward and assert unchanged RNG through recomputation. All 36 framework tests pass. Separate structural probes verified shifted labels, causal masking, padded-source invariance and full-prefix versus incremental decoding; the production model's encoder/cross-attention gradients were finite and nonzero. These checks identify a real update error, not a guarantee that it explains all observed quality degradation or that old weights are repaired. See [the correction and checkpoint compatibility](../llm/pinyin_to_text/README.md#mps-checkpointdropout-correction).

A controlled 0.403B probe started from the same existing step-9,900 weights before/after the fix, using fresh AdamW, dropout 0.1, batch 2/accumulation 4 and the same eight authored training pairs repeated for 30 updates. Beam-2 top-1 memorization went from 0/8 to 5/8 before the fix and from 0/8 to 8/8 after it. Both in-memory models were discarded without saving weights; the original checkpoint SHA-256 still matches its earlier evaluation report. This is a tiny memorization experiment, not restored validation/test quality. The same real pipeline on a separate tiny model learned 7/8 at 40 exposures and 8/8 at 160 on both CPU/MPS. All 381 Swift tests and the Debug build also passed. Local aggregate evidence is in ignored `llm/pinyin_to_text/reports/training-audit-20261027.json`; no new formal run was started.

Run `./llm/pinyin_to_text/scripts/setup.sh --offline` for an already installed environment, `./llm/pinyin_to_text/scripts/check.sh` for regression coverage, and `./llm/pinyin_to_text/scripts/smoke.sh --output NEW_DIRECTORY` for a small CPU workflow check. The source is maintained CSV data; no dynamic-generation/JSONL-source tests or dependencies remain. Shell workflow checks need normal OpenMP shared-memory access if a restricted execution sandbox aborts a PyTorch subprocess.

Coverage includes explicit train/validation/test assignment, category discovery, BOM/quoting, optional language, exact text preservation, static typo pairs, duplicate memberships, source declarations, cross-split rejection, immutable snapshots, train-only vocabulary, lossless Unicode fallback, malformed config/data rejection, actual learning on a synthetic pair, causal decoding, 0.4B parameter counting, exact resume with dropout/checkpointing/epoch rollover, no test reads during training, report comparison, external CSV benchmark separation, inference export and loading preserved model configs without their original source files. An MPS regression compares varied padded attention shapes against CPU at `atol=rtol=1e-4`.

The maintained collection has 24 CSV files and 50,000 unique samples: 47,339 train, 1,361 validation and 1,300 test. Training's twelve fine-grained vocabulary files were merged into `train/words.csv` with all 1,350 pairs preserved and no duplicates. Validation and test each consolidate eleven vocabulary files into their own `words.csv`, preserving 75 and 74 pairs respectively. The 59 chat files were consolidated into one `chat.csv` per split, preserving all original 4,728 pairs (4,001 train, 373 validation, 354 test); the subsequent expansion adds 22,000 training chat pairs. Every original sample and its split remain preserved. Current prepared CSV snapshots remain. Obsolete seeds/generators/configs, generated raw/prepared data and their smoke outputs were removed; trained weights remain inference-only artifacts. Small-model smoke checks are partial synthetic evaluations, not production accuracy measurements, and do not start a formal 0.4B run.

After the chat consolidation on October 26, 2026, full preparation into a temporary directory and all 34 framework tests passed, including the MPS numerical check. The initial restricted run hit OpenMP shared-memory errors in three subprocess tests; the normal-permission rerun passed. Chat row multisets, all prepared sample identities and the 41 unrelated CSV file hashes matched their pre-merge values. No existing prepared dataset or formal training run was replaced or restarted.

The subsequent validation/test vocabulary consolidation passed full preparation into a temporary directory, exact row-multiset comparison for all 149 vocabulary pairs, sample-identity comparison across all splits and hash checks for the 22 unrelated CSV files. No runtime code changed; the framework suite was not repeated for this additional data-only consolidation.

The [50,000-sample expansion](../llm/pinyin_to_text/data/csv/EXPANSION_50K.md) on October 26, 2026 added 31,027 distinct training pairs: 22,000 Chinese, 5,000 English, 3,000 mixed and 1,027 synthetic typos. All original sample identities, original byte prefixes of the four edited files and hashes of the other 20 CSVs passed preservation checks. All 25,000 clean Chinese/mixed pairs passed character-reading/literal-byte alignment; source/target normalized cross-split checks passed. Full preparation with the production config created `llm/pinyin_to_text/data/prepared/static-csv-50k-v1`; maximum training input/target token lengths are 71/71 within 256/128 limits. All 34 framework tests passed, including the MPS comparison. The expanded CSV root also passed the four-step CPU train/resume smoke, three-case validation/test evaluations and literal-fallback checks. An independent CSV recount, every frozen bundle file hash, every prepared sample identity, all 2,500 English variant pairs and all 1,027 adjacent swaps were checked. This is synthetic data validation, not a full training or representative quality result.

On October 26, 2026, all 34 current framework tests passed after replacing the combined training/evaluation entry point with separate preset scripts. Tiny CPU fixtures exercise no-argument data preparation, training, full validation/test and export as separate invocations: preparation creates no training run, training creates no candidate reports/export, and validation creates no test report. Regression checks preserve existing data/runs and literal-baseline argument overrides. A recording interpreter verifies each default entry point dispatches exactly one module with the MPS/versioned-path presets without running the formal model. Offline setup after removing the unused pronunciation package, the CSV-only CPU smoke, the repository Swift tests and the Debug build also passed during cleanup. Useful Unicode/tokenizer and resume checks were retained while generation-only tests were removed. A regression confirms that preserved older model configurations still load for inference without their deleted source data. No formal 0.4B training was restarted.

## App interface localization

Run `./scripts/test.sh` and `./scripts/build.sh`. `LocalizationTests` checks English/Simplified Chinese resource parity and format arguments, macOS language negotiation for regional variants, English fallback, translated controls and exact user-text substitution. `CandidateDescriptionTests` checks existing English meanings, translated metadata and unchanged candidate identity/commit bytes. Presentation and dictionary tests use the current localized labels rather than assuming the test process runs in English. Inspect the built app for both `en.lproj/Localizable.strings` and `zh-Hans.lproj/Localizable.strings`.

On October 26, 2026, all 347 Swift tests passed (258 core, 69 presentation, 14 settings, 3 storage and 3 localization), and the Debug app built successfully. Both resource tables passed `plutil -lint`, and the built app contains both localizations. A standalone probe linked the app's Debug objects, without starting an InputMethodKit server or loading personal archives, and rendered Settings, the phrase manager/editor and app-data manager with synthetic empty data in both languages/appearances. Inspected previews confirmed native SwiftUI localization and wrapped editor instructions after fixing their truncation. This is offscreen layout evidence, not live keyboard, VoiceOver, input-menu or system-language-switching verification. No input method was installed or user language preference changed.

On an intentionally installed build, test English and Simplified Chinese using macOS's per-app language preference and restart SI normally between languages. Do not run built and installed copies together. Check Settings, every manager/editor, destructive confirmations, validation/storage errors, file panels, update availability, input-menu actions, candidate tooltips, paging/expansion and accessibility descriptions. Use keyboard-only navigation, VoiceOver and both appearances; check long explanations and narrow windows. Input languages and consent must remain unchanged when the UI language changes. Confirm synthetic `SI_build42`, decomposed Unicode, app identifiers and personal phrase text remain exact; E/C/A badges stay recognizable. Native InputMethodKit menus, spoken VoiceOver, system language switching and update dialogs require separate live verification.

## Settings cleanup

Settings no longer includes the Try the candidate engine section or its application picker, input field, results and paging controls. Its dedicated view, asynchronous model and tests have been removed; input-method full/provisional candidate generation remains in place.

On October 26, 2026, all 342 remaining Swift tests passed (258 core, 67 presentation, 14 settings and 3 storage), and the Debug app built successfully. The four removed tests covered only the deleted Settings preview model.

On an intentionally installed build, open Settings and confirm Languages, Typing, Direct Input by Application, Personal Learning, Personal Phrases and update controls remain accessible by keyboard and VoiceOver in light/dark appearance. Confirm there is no candidate-engine trial section. These native UI checks remain unverified for this cleanup.

## Direct input by application

Run `./scripts/test.sh` and `./scripts/build.sh`. `LanguageSettingsTests` checks initially disabled app rules, application scoping, restart persistence, unchanged language/consent settings and configuration invalidation. `ApplicationDiscoveryTests` uses temporary synthetic bundles to check grouped applications, duplicate identifiers, exclusion of nested helpers, explicitly selected apps outside the search roots, display names and rejection of missing identifiers. These automated checks do not exercise InputMethodKit event delivery.

On October 26, 2026, all 346 Swift tests passed (258 core, 67 presentation, 18 settings, 3 storage) and the Debug app built successfully, including after adding application icons. A standalone discovery probe using the production scanner found 124 apps in the local standard Applications folders, including system Terminal, with no duplicate identifiers. No app list or input content was saved by the probe. An offscreen row render was visually inspected for Terminal's system icon and the generic icon for a missing app. This does not verify the live Settings interface or host input behavior.

Check that discovered and manually added apps show their system icons, missing apps show a generic icon, and icons stay aligned with names and switches while filtering and scrolling. Icons are decorative: VoiceOver should read the app switch's label once without a separate image announcement.

On an intentionally installed build, open **Direct Input by Application → Manage Direct Input…**. Search for Terminal by name and bundle identifier, enable its switch, close/reopen Settings and restart SI normally to check persistence. Confirm standard-folder and running apps appear, Refresh picks up changes, Add Application accepts an app elsewhere, and an enabled missing app remains removable by its identifier. Check the search, switches, file picker and Done button using the keyboard and VoiceOver, in light/dark appearance and Increased Contrast.

In a selected Terminal app, type synthetic `echo SI_TEST_42`, use Space, digits, Tab completion, Return, arrows, Home/End, Delete, Escape and Control shortcuts. Every key must reach the host once, without candidates, automatic spacing or an extra Return to finish composition. Repeat with punctuation candidates and automatic confirmation enabled. Switch to TextEdit and verify ordinary Chinese/English candidates, selection and literal Return still work. A browser rule must apply to both its address bar and page inputs; an editor rule must apply to both editor and embedded terminal. No system input-source selection or Accessibility/Input Monitoring prompt should occur.

Toggle direct input across a pending composition/search or pause timer, then return to the host, use candidate mouse/page/expansion controls if still visible and change focus rapidly. Only the exact pending source spelling may be inserted, once, with no extra space; obsolete candidates/timers must not convert or restore it. Turn direct input off and verify fresh conversion, without stale selection or history. With vocabulary/history independently opted in, confirm direct input adds no app records or incomplete history suffix, including after Return; existing records must remain deletable. Inspect data only with synthetic input. Native host, reentry, VoiceOver and appearance checks remain unverified until performed in a login session.

On November 4, 2026, the application-language redesign was reverted to the independent Direct Input by Application switch. `./scripts/test.sh` passed all 430 Swift tests and `./scripts/build.sh` built the Debug app successfully, using ordinary compiler/cache access outside the agent sandbox. Documentation links and `git diff --check` passed. No input method was installed or launched, and native host/VoiceOver behavior was not retested.

## Experimental permissions

Run `./scripts/test.sh` and `./scripts/build.sh`. Permission controls are separate from language, direct-input, learning and history settings. No focused-control detection or field-based automatic input behavior is implemented.

On an intentionally installed build, open **Experimental Permissions** and verify keyboard navigation, VoiceOver labels and light/dark appearance. Invoke each request button separately, test denial/retry and authorization in Privacy & Security, then return and refresh status. Neither launching SI nor typing should prompt. If macOS requires a restart, restart the installed copy normally without running a second SI process. Granting either or both permissions must leave ordinary candidates, enabled languages, direct-input app rules and learning/history consent unchanged. No controls or images should be captured.

System permission dialogs, revocation, Settings keyboard/VoiceOver and live appearance remain unverified until exercised in the login session.

On November 3, 2026, removing the app-specific address-bar experiment while retaining the generic permission actions passed all 444 Swift tests (307 core, 98 presentation, 23 settings, 13 storage and three localization) using `./scripts/test.sh --disable-sandbox`, plus the Debug build with `./scripts/build.sh`. The SwiftPM nested sandbox fallback and standard Xcode cache access outside the workspace sandbox were required. Localization lint, local Markdown targets and `git diff --check` passed. The removed experiment's three tests were deleted with its implementation. No input method was installed or launched, no permissions were granted, and no host controls or images were inspected.

## Mixed English lookup

`MixedEnglishSpacingTests` checks one space at Chinese/English boundaries and
between adjacent English words in mixed
provisional/full candidates, including `lianxiandan` → `联系 and an` and the
`联系 and a` prefix. It covers English runs before/after Chinese, interleaving,
casing, final-word completion, exact literal Return, whole/prefix commits,
apostrophe and `ü/u:` source boundaries, continuation joins/projections and
compatible-prefix UTF-8 alignment. These spacing checks do not establish that
the mixed hypotheses are appropriate Chinese conversions or fix their ranking.
Run `./scripts/test.sh --disable-sandbox --filter MixedEnglishSpacingTests`.

Before Chinese/English boundary spacing was added, on October 28, 2026, the seven related spacing, English/mixed and continuation
suites passed all 46 tests, and `./scripts/build.sh` completed the Debug build.
`./scripts/test.sh --disable-sandbox` ran 392 tests with one failure in
`CandidateEngineTests.prefixLearningUsesConsumedSpellingWithoutAReservedPosition`;
that fixed-provider ranking fixture does not exercise lexical spacing or source
traces. The working tree's separate prefix-ranking edits were left intact. No
input method was installed and no native host check was performed for spacing.

After adding Chinese/English boundary spaces on October 28, 2026,
`./scripts/test.sh --disable-sandbox` passed all 396 tests (288 core, 83
presentation, 15 settings, 7 storage and 3 localization), including the previously
failing prefix-learning fixture in the current working tree.
`./scripts/build.sh` completed the Debug build. Preview/full output, whole/prefix
commits, continuation text and exact UTF-8/source alignment have automated
coverage. Personal/verbatim output retains its existing exact-byte behavior.
No input method was installed; native host checks remain unverified.

On an intentionally installed build, enter `lianxiandan`, `nihaohelloworld` and
`helloworldzhongwen` in TextEdit and a browser field. Compare initial/full
candidates and confirm spaced choices with Space, digits and mouse. The
`联系 and a` prefix must leave exactly `n` editable, with no trailing acceptance
space. Check Return, Escape, edits, shortcuts and focus changes. Native host
verification remains separate from the core tests.

Run `./scripts/test.sh --filter 'MixedLexicalIntegrationTests|MixedInputTests|MixedWordBoundaryTests|EnglishSentenceTests|EnglishVocabularyTests|ChineseSegmentationTests|ChineseMigrationTests|SequentialWordSelectionTests'` and `./scripts/benchmark.sh`. The new synthetic regressions cover `woxiangyaodeploy` and `wo'xiang'yao'deploy` → `我想要 deploy` as the preview/full leader, disabled languages, exact English words, preserved English case, interleaving, final English completion, literal commits, normalized umlaut prefix consumption, stale delivery, personal/verbatim learning exclusion and absence of mixed automatic-confirmation evidence. Existing suites continue to expose unimplemented initial/fuzzy/Chinese-tail and migration quality cases.

On an intentionally installed build with both languages enabled, type `woxiangyaodeploy`, `woxiangyaoDEPLOY`, `deployzhongwen`, `woaiSwiftshurufa` and `woxiangyaodeplo` in TextEdit, a browser text field, an editor and Terminal. Compare hints/full results, then use Space, numbers and mouse confirmation in both layouts. Confirm an English-ending prefix leaves the exact Chinese remainder marked without inserting a space; test Left/Right edits, Escape, literal Return, shortcuts and focus changes while work is pending. Disable English and check mixed candidates disappear. English words such as `deploy`/`title` and continuous `iwanttobuild` must retain their English identities/spacing; pure Chinese `woxianganzhao` must retain its leader. These native checks remain separate from core tests and synthetic timings.

## Shared dictionary format

`BundledChineseDictionaryTests` scans the packaged Chinese SQLite rows for Unicode private-use characters and checks that a normal extension-block Han entry remains available. On October 26, 2026, the SI overlay removed all 85 private-use readings (70 characters), leaving 953,625 entries. A direct comparison with the preceding database confirmed that every retained row, weight, row ID and relative order was unchanged. SQLite integrity, offline Chinese/English dictionary checks, vocabulary/ranking checks, all 36 Python maintenance tests, the full Swift test command and the Debug build passed. The Debug app's Chinese database matches the rebuilt resource. No installation or live host check was performed for this data cleanup.

Run `python3 scripts/csv_dictionary.py build --check`, `python3 scripts/msime_dictionary.py build --check` (including context hashes), and `python3 -m unittest discover -s Tests/VocabularyTests -v`. The CSV compiler reproduces both SQLite resources offline, checking schema, metadata, exact generated row IDs/data, indexes, category file hashes, provenance and retained database checksums. Synthetic fixtures exercise automatic category discovery, moving/reordering rows and renaming categories without changing ties, maximum-weight duplicate merging, distinct reading/Unicode preservation, additions/deletions/weight edits, quoted CSV/BOM/CRLF, exact Unicode bytes, casing uniqueness, invalid-input preservation across both languages, stale resources and cross-SQLite-version checks. Retired source-import/snapshot tests have been removed with their old word/frequency files. Attribution/calibration tests and inline metadata validation remain independent of editable CSV content. `DictionaryDatabaseTests` verifies bundled schemas/units, concurrent lookups and read-only failure for missing/incompatible resources. English lookup/trie/completion tests use bundled SQLite rows as reference.

For the initial Chinese category split, compare the exact `(text, reading, weight)` row multiset against the preceding base file, reject duplicate identities and require all readings of each output to share a category. Rebuild/check the full collection and compare both SQLite dictionary hashes and pinned context hashes with their pre-split values. Category membership is maintenance data: no score, lookup, candidate order or commit change should result. The category guide documents conservative first-pass boundaries; automated data equality does not establish exhaustive semantic classification.

Run `./scripts/test.sh` and `./scripts/build.sh`. On an intentionally installed build, check English-only and combined-language `he`, `shi`, `abilit`, `Gmail`, `GMAIL`, `iwanttobuild` and an unknown synthetic identifier in TextEdit and a browser field. Exercise selection, exact literal Return, cancellation, shortcuts and focus changes; compare initial hints with full candidates and verify capitalization. No installation is required for ordinary code validation. Database parity and core tests do not establish host compatibility, cross-language sentence-score calibration or restoration of mixed lexical paths.

On October 24, 2026, ten failing core test functions were removed at the user's request. The remaining 342 Swift tests pass (258 core, 67 presentation, 14 settings and 3 storage), and the Debug app builds. Removed coverage includes abbreviation/full-spelling retention, personalized search and terminal compaction, mixed token learning, trailing spelling separators, normalized aliases, prefix ranking and standard-vocabulary automatic confirmation. These deletions do not resolve the underlying behaviors. Earlier failing-suite results remain historical evidence; see [the current evidence](VERIFICATION.md).

For candidate refresh changes, run `./scripts/test.sh --filter 'MarkedTextStateTests|unchangedPreviewAndFinalResultsKeepTheExistingRows|CandidatePipelineTests|CandidatePlacementTests'`. The marked-text fixture exercises append → provisional → final delivery, caret movement, cancellation, exact Unicode bytes and reset; the view fixture checks row retention and interaction in both layouts. On an intentionally installed build, type synthetic `jintjiushi` rapidly and slowly, then edit, page, cancel and change focus. Watch for transient windows at the display corner and host/preedit or candidate-panel flicker. Repeat in a browser and TextEdit; automated geometry and view checks do not identify the owner of a transient native window.

`CandidatePanelOwnershipTests` checks two offscreen client panels, late old-client deactivation, and rejection of a stale panel's render/show request without displaying test windows. The placement suite reproduces an established document anchor followed by temporary misses and a valid-looking screen-corner legacy fallback; it must retain the established anchor, then follow fresh document reflow. In live hosts, switch rapidly between two text fields/apps while full decoding is pending, continue typing, and commit/cancel. Only the active client's panel may appear. Check first composition, document reflow and display changes as well as the cached-position case; source tests do not validate actual IMK activation/deactivation or synchronous reentry delivery.

Chinese maintenance is consolidated to MSIME. English spellings and functionality are retained in the shared SQLite format, with initial frequency estimates converted to the common relative-weight unit. `DictionaryConsolidationTests` checks that Chinese `ne` still leads with `呢`, English `new`/`need`/`next` remain available, and exact literal input is preserved.

`ChineseFrequencyRankingTests` checks the reported `nawomenzaichaxun` sentence in provisional/full searches, Chinese-only/combined settings and apostrophe-separated input, with exact literal/prefix boundaries. Injected fixtures require a tenfold frequency advantage to beat an all-multi-character segmentation, keep rare words and explicit learning available, and test longer low-frequency fragments. `haodewozhidaole` guards against the over-splitting observed when the character cost was removed entirely. Run `./scripts/test.sh --filter 'ChineseFrequencyRankingTests|ChineseMigrationTests|InputQualityTests|DictionaryConsolidationTests'`. These tests do not operate a live host or establish general semantic accuracy.

`ChineseSegmentationTests` covers `woxianganzhao` → `我想按照` in preview/final generation with Chinese-only and combined languages, including explicit/partial separators and inputs longer than four syllables. Injected lexicons check frequency competition across cuts, insertion-order independence, exact `ü/u:` prefix commits, deliberate learning and clear, unchanged visible results with confirmation evidence, disagreement vetoes and the deterministic 32-cut bound. On an intentionally installed build, repeat `woxianganzhao` and `wo'xiang'an'zhao` in TextEdit and a browser field, confirm with Space/number/mouse, then edit, cancel, use a shortcut and change focus. Check that choosing `我想` consumes exactly `woxiang` and leaves `anzhao` editable. These native checks remain separate from the core tests. The benchmark includes the reported ambiguous boundary and ten repeated `fangan` spans.

## Shared candidate scoring

`CandidateScoringTests` verifies score-ordered Chinese/English/mixed whole candidates, the reported `ling` → `零` versus `里 NG` comparison in provisional/full results, the same lexical costs across decoders, spelling completion costs, language filtering, deterministic identities, literal fallback and pinned-personal overrides. `CandidateSelectionTests.lingKeepsHigherScoringHomophonesWithoutReservingItsMixedAlternative` verifies shortlist survival, expanded numbering and committing `零`. Run `./scripts/test.sh --filter CandidateScoringTests` for the focused core checks. The shared cost formula and remaining quality limits are in [candidate ranking](UNIFIED_RANKING.md).

In two host apps, enter `ling`, expand the list and verify `零` appears before `里 NG`, English choices and exact `ling` remain available, and Space/digits/mouse commit the selected text exactly once. Compare Chinese-only and bilingual settings, initial hints and final results, then check focus changes, Return, shortcuts and prefix remainders. Candidate placement follows scores: this does not promise five Chinese entries in the compact strip. Unpinned personal phrases remain available by score; exact pinned phrases retain their explicit override. No native host check has been performed for this formula change.

## Reduced word and character penalties

The October 31 synthetic comparison reduces the shared per-word insertion cost
from 20 to 19.5 nats and the additional Chinese-character cost from two to 1.75
nats. Dictionary weights, spelling channels, language transitions and confirmation
costs retain their existing definitions. English, Chinese, mixed and personal
lexical paths use the same shared word cost; no phrase-specific rule is added.

| Word cost / character cost, nats | Existing first-choice hits / 86 | Existing top-five hits / 86 |
| --- | --- | --- |
| 20 / 2, baseline | 82 | 86 |
| 20 / 1 | 81 | 86 |
| 19 / 1.5 | 80 | 86 |
| 19.5 / 1.75, selected | 81 | 86 |

These are known development/regression fixtures, not independent accuracy data.
With the selected costs, `diqiye` changes from `第七页` to `地企业`; `第七页`
remains second in both preview and full search. `dijiuye` retains `第九页` first.
The reported `heshangcibi` case is additional to these 86 examples: `和上次比`
scores -34.790479 versus -34.954909 for `和尚刺鼻`. The formula does not judge
semantic compatibility, and lowering both costs cannot preserve every homophone
or segmentation ranking.

Run `./scripts/test.sh --filter ChineseFrequencyRankingTests`, the full
`./scripts/test.sh`, `./scripts/benchmark.sh --quality`, and
`./scripts/build.sh`. The new regressions cover Chinese-only/bilingual settings,
preview/full ranking, explicit apostrophes, shortlist order, retained alternatives,
literal preservation, exact default commits and an unrelated-text injected
three-word/two-word comparison in both dictionary insertion orders. Existing
independent arithmetic/exhaustive-search fixtures use the new constants.

On October 31, all 401 Swift tests passed (289 core, 87 presentation, 15 settings,
seven storage and three localization), and the Debug app built successfully.
Independent read-only SQLite calculations matched the six recorded sentence
scores, including both reported homophones. Final quality results retain all 86
targets in the engine and top five, with preview/full first-choice agreement on
all 86. Logs and reports are under `.build/heshangcibi-*`. No input method was
installed, no personal archive was read and no native host check was performed.

On an intentionally installed build, type synthetic `heshangcibi`,
`he'shang'ci'bi`, `diqiye`, `dijiuye`, `xian` and `haodewozhidaole` in TextEdit
and a browser with app vocabulary disabled. Check preview/full refresh, Space,
numbers, mouse selection, prefix remainders, Return, Escape, shortcuts and focus
changes. This change does not install or launch the input method; native host
behavior remains unverified.

## Stronger dictionary-frequency weighting

After the penalty comparison above, the same October 31 checkout compared
log-frequency coefficients with the 19.5/1.75-nat insertion costs fixed:

| Log-frequency coefficient | Existing first-choice hits / 86 | Existing top-five hits / 86 |
| --- | --- | --- |
| 1, prior step | 81 | 86 |
| 1.05, selected | 80 | 86 |
| 1.10 | 74 | 86 |

The selected formula is
`(19.5 - 1.05 * ln(max(1, weight)) + (single Chinese character ? 1.75 : 0)) / ln(2)`.
It increases dictionary-frequency influence rather than changing stored weights,
spelling channels, language transitions, prefix confirmation costs or preference
bonuses. All decoders and direct/prefix/personal lexical paths share this formula.
Unknown weight one retains its old cost. The upstream ranking weights are not
calibrated occurrence probabilities, and this coefficient is a heuristic.

`和上次比` now scores -31.986482 and `和尚刺鼻` -33.821739, increasing the
reported comparison's margin from 0.164430 to 1.835257 bits. On the existing
fixtures, `dijiuye` additionally changes from `第九页` to `地就业`; the target
remains second in preview/full search. The 1.10 experiment also favors `第二也`,
`第三也`, `第四也`, `第五也` and `而也` over the corresponding supplied targets.
The 1.05 results retain all 86 targets in the engine and top five, with preview/full
first-choice agreement on all 86. These are known development/regression examples,
not independent accuracy evidence or semantic-quality improvement claims.

The final same-checkout control comparison, including the independent continuation
fix, reproduces 81 versus 80 first choices for coefficients one versus 1.05. Only
`dijiuye` changes first choice in that comparison. The new injected regression
fails all four preview/full/insertion-order cases with coefficient one and passes
with 1.05; it tests a score-ordering change rather than a formula identity.

On October 31, the final `./scripts/test.sh` passed all 404 Swift tests (291
core, 88 presentation, 15 settings, seven storage and three localization), and
`./scripts/build.sh` built the Debug app, including the independently modified
continuation scoring present in the shared worktree. The new injected regression
requires a frequency advantage to overcome one additional word and two single-character
costs, checks preview/full output in both dictionary insertion orders, and keeps
the rarer alternative. Existing shared-cost, exhaustive-search, cross-decoder,
learning, literal, shortlist and exact-commit checks pass with the new coefficient.
Independent read-only SQLite arithmetic supplies the updated fixed-path scores.
Quality reports and build/test logs are under `.build/frequency-weight-*`.

For focused checks, run `./scripts/test.sh --filter ChineseFrequencyRankingTests`
and `./scripts/benchmark.sh --quality`. Repeat the synthetic native host checks
in the preceding section, including ordinal alternatives and app-vocabulary
pause/clear. No input method was installed or launched and native host behavior
remains unverified.

## Prefix scoring and quality reports

Run `./scripts/test.sh --filter 'CompositionCoverageTests|CandidateEngineTests|WholeWordCandidateTests|PartialCommitTests|ChineseSegmentationTests|AutomaticConfirmationTests'`.
Candidate comparison uses only consumed spelling. Tests retain continuous input,
preview/final delivery, default selection of the actual leading candidate,
explicit remainders, exact bytes/aliases, caps, stale results and automatic
confirmation. Prefix scores do not include the pending remainder's costs or
preferences. The earlier full-input projection policy has been removed.

`./scripts/benchmark.sh --quality` evaluates the actual `CandidateShortlist`,
including prefixes, and counts only complete nonliteral target matches. `rank`
and top-five reflect window policy before machine-specific font filtering;
`engineRank`, `wholeRank` and `wholeTopFive` distinguish search, whole-decoding
and shortlist failures. Short-prefix dominance can reduce visible full-sentence
recall. Sentence-only regression tests do not measure window quality. These
fixed development/historical fixtures are not independent quality evidence.

For native checks, repeat the [consumed-only prefix cases](#consumed-only-prefix-ranking)
in two host apps. Verify default Space commits the displayed choice, including
an editable remainder when it is a prefix; whole-input conversion has no reserved
position. No native-host claim follows from core or offscreen tests.

## Four leading hypotheses and word selection

Run `./scripts/test.sh --filter 'ChineseSentenceAlternativesTests|FirstWordPrefixTests|SequentialWordSelectionTests|leadingSentenceCanBeClickedAndCommittedInBothLayouts'`. Sentence search still emits six distinct base terminal readings and a separate bounded personalized lane. The window retains constructed hypotheses only from the first four ranked choices and fills its remaining capacity with words rather than additional sentences or multiword fragments. First results and complete words have no per-language reservation. The first four ranked choices may mix hypotheses and words; lower-ranked fragments must not displace words or move ahead of them. Every retained nonliteral choice preserves engine order; explicit pins, language identity and the exact literal remain covered. Fewer than four hypotheses must not be duplicated or backfilled with lower sentences after the word tail. Engine recall of `erbeizuoduo` → `二倍做多` remains tested; its survival in the four-hypothesis window is no longer promised.

`SequentialWordSelectionTests.reportedTitleKeepsItsFirstCharacterSelectableWithExactRemainder` covers `sheguofennudehai` and apostrophe-separated input, Chinese-only/bilingual settings, provisional/full results, both layouts, four leading constructed choices and a word-only tail. Choosing `涉` consumes only `she` (including a following separator when present), keeping the exact remainder editable. `reportedTitleCanBeChosenWordByWordFromTheRenderedPages` completes `涉` → `过` → `愤怒` → `的` → `海`, checking numbered selection, mouse identities and accessibility labels in light/dark compact/expanded views. Set `SI_TITLE_PREFIX_SNAPSHOT_PATH=/tmp/si-title-prefix` to retain its actual first pages. This does not establish title-level semantic accuracy or live host routing.

On October 26, 2026, all 350 Swift tests passed (259 core, 71 presentation, 14 settings, 3 storage and 3 localization), and the Debug app built successfully. The focused title/prefix/alternative checks passed, and light/dark compact/expanded first-page renders were inspected.

On an intentionally installed build, repeat these spellings in TextEdit and a browser field. Check four leading sentence/fragment choices followed by words, without extra sentences on later pages. Select words with digits, Space and the mouse, checking exact remainders, Return, Escape, edits, shortcuts, focus changes and VoiceOver. Compare both language configurations, provisional/full results, ordinary `ling`/`xianshi`, pinned phrases, punctuation options and opted-in app vocabulary. No input method was installed or live host/VoiceOver check performed for this change.

## Down Arrow expansion and candidate grid

Run `./scripts/test.sh --filter 'CandidateSelectionTests|CandidateViewTests|CharacterPagingTests|FirstWordPrefixTests'`. Down Arrow while collapsed expands without advancing selection; Left/Right switches the selected candidate. Expanded Left/Right changes columns and Up/Down changes rows within the page. The whole four-row/six-column grid is one page (24 choices), with Page Up/Down and footer buttons changing pages. Repeated numbers 1–6 act on the active row; all displayed cells remain clickable. Tests cover edge clamping, incomplete last rows/pages, preserved cell position where available, expansion/collapse, real `NSEvent` mappings and localized page/row/column help. Digits 7–9 are not candidate shortcuts.

`CharacterPagingTests` traverses more than three whole grid pages of 80 injected homophones, including candidates beyond the former 27-choice cap. Row/column navigation, displayed mouse identity and active-row digit selection must choose the same character; committing it consumes only its exact spelling and leaves the remainder editable. Core fixtures verify all complete-syllable dictionary characters in preview/full lookup and prefix pools, including the bundled `she` readings and apostrophe-separated source boundaries. Ordinary word slots remain bounded, and non-character word learning still exercises the 24-word pool. These are exact dictionary-recall checks, not general typo/initial/sentence coverage claims.

`expandedGridSharesContentSizedColumnsAcrossFourRows` preserves first-row identities while allowing expanded columns to grow for lower rows, checks four rows of six, and constrains the grid to 340 points. Every row must share the column origins/widths and number/text insets in both appearances. Rows must remain above the footer and within the card. Tight cells reserve space for a number and glyph and hide source icons; text clipped on narrow screens remains exact in tooltips and accessibility labels. Set `SI_GRID_SNAPSHOT_PATH=/tmp/si-grid-six` to retain light/dark regular and narrow renders. Expanded rows use compact source icons and punctuation badges.

On October 26, 2026, all 356 Swift tests passed (261 core, 75 presentation, 14 settings, 3 storage and 3 localization), and the Debug app built. Both localization tables passed `plutil -lint`. Light/dark regular/narrow grids and distant final-page selected-cell renders were inspected. Set `SI_SPATIAL_PAGING_SNAPSHOT_PATH=/tmp/si-spatial-paging` for the latter. No input method was installed.

On an intentionally installed build, type synthetic `sheguofennudehai` and `shi` in TextEdit and a browser field. Check collapsed Left/Right selects candidates without editing marked spelling, and Down opens the grid without advancing. Expanded arrows must move by row/column within one four-row page; Page Up/Down and footer buttons change whole pages. Confirm page counts, all retained single-character alternatives on later pages, short last rows, digits 1–6 on the active row and clicks on other rows. Check first-row column alignment, fitted selection backgrounds, Home/End caret editing, collapse, pending results, focus changes, shortcuts, cancellation, narrow displays, light/dark appearance and VoiceOver. Outside composition navigation belongs to the host. Native IMK event delivery and spoken accessibility remain unverified by offscreen tests.

## Automated checks

For exact-spelling ranking, run `./scripts/test.sh --filter 'CandidateScoringTests|UnifiedRankingTests|SpellingEvidenceTests|UnifiedRankingPresentationTests'`. With both languages enabled and an empty learning profile, check `ma` → `吗`, `ne` → `呢` and exact English `man` in provisional/full results. The `ma` presentation regression checks first-choice numbering, retained English completions/literal and exact commits in both layouts. Finite-channel tests verify normalization and the stronger complete-spelling endpoint; formula fixtures independently check the new weights. Compare `./scripts/benchmark.sh --quality` against the recorded baseline, including unfinished English words and continuous sentence splits.

On an intentionally installed build, repeat `ma`, `ne`, `man`, `togethe` and `performa` in TextEdit and a browser field, with Chinese-only, English-only and bilingual settings as relevant. Check compact/expanded selection with Space, digits and mouse, then Return, Escape, shortcuts and focus changes. Verify normalized umlaut prefix commits still leave the exact remainder editable. Core/offscreen checks do not establish native host routing, VoiceOver or candidate positioning.

```sh
python3 scripts/csv_dictionary.py build --check
python3 scripts/msime_dictionary.py build --check
python3 scripts/ranking.py --check
python3 -m unittest discover -s Tests/VocabularyTests -v
python3 -m unittest discover -s Tests/ScriptTests -v
./scripts/test.sh
./scripts/build.sh
./scripts/benchmark.sh
./scripts/benchmark.sh --previews
./scripts/benchmark.sh --quality
./scripts/benchmark.sh --resources > .build/candidate-benchmark.json 2> .build/resource-usage.log
```

`UnifiedRankingTests` independently checks probability/unknown normalization, conditional pronunciation, Witten–Bell boundary interpolation, finite spelling-channel mass, exact/composed unit consistency, deterministic initialization and cached versus unbounded English preview ranking. Exhaustive small-lexicon regressions compare optimal costs with floating-point tolerance and require identical output bytes across insertion orders. `UnifiedRankingPresentationTests` checks bilingual `abilit` → `ability` through both generation stages/layouts, literal retention, exact commit spelling and the absence of per-language reservations. `--quality` reads only fixed synthetic JSON fixtures and reports development/regression and later holdout partitions separately; it never reads a user's archive or host text. See [model/provenance](UNIFIED_RANKING.md).

CSV vocabulary checks run offline and verify deterministic generation, category discovery, explicit corrections/deletions, checksums, duplicate merging and failure preservation. Inline source metadata and retained license/attribution text are checked without old source wordlists or frequency archives. Network refresh/audit checks are separate manual maintainer actions and do not install SI. See [English vocabulary maintenance](ENGLISH_VOCABULARY.md) and [Chinese vocabulary maintenance](CHINESE_VOCABULARY.md).

The reinstall script checks use isolated process-command and installer fixtures. They verify current-user/exact-name matching, graceful exit, forced-stop fallback, failure handling, argument validation, and installer status propagation without stopping SI or installing an app.

The release script checks use synthetic artifacts and mocked storage/commands to verify signing requirements, dry-run isolation, dirty-checkout rejection, rejected notarization cleanup, immutable-object conflicts, authentication errors, anonymous checksum failures, channel ordering, downgrade prevention and conditional promotion after a competing release. Installer fixtures additionally cover home-only/logout metadata, fresh installation, current/legacy backups, root/foreign-bundle/symlink rejection, process-query failures, backup failures and a process restarting during backup. They never contact Apple/R2 or install SI. For real packaging, run `./scripts/package-dmg.sh --output-dir .build/dmg-check`, verify the image/checksum and mount it read-only to inspect `Install SI.pkg`, instructions and license. Query the package with `installer -query RestartAction -pkg <package>` (expect `RequireLogout`) and `installer -dominfo -pkg <package>` (expect only `CurrentUserHomeDirectory`); these queries do not install. Expand it with `pkgutil --expand-full <package> <new-directory>` to check the embedded payload, executable architecture slices and strict app signature. Signed/publication checks additionally require actual Application/Installer certificates, profile access, accepted notarization, a valid stapled ticket, verified public downloads and channel JSON. Follow [RELEASING.md](RELEASING.md); do not publish as incidental test setup.

Initial app-only DMG verification on October 20, 2026: all 153 shared-core tests and 22 script tests passed, and Debug/Release builds succeeded with Xcode 27.1. Created an ad hoc signed Universal Release DMG, checked its SHA-256, mounted it read-only, verified the bundle identity/version, both executable slices, strict nested signature verification, license bytes and Input Methods instructions, then detached it. Shell syntax, Python 3.9 grammar compatibility and release dry-run checks passed. Compiler builds required execution outside the restricted sandbox. Developer ID signing, Apple notarization, R2 upload/public-download/channel behavior and installation/host compatibility were not exercised against live services or a login session.

Native Installer/logout verification on October 20, 2026: all 157 shared-core tests and 29 script tests passed; Debug, Release and Universal packaging builds succeeded. Mounted the new DMG read-only, expanded its package, verified the embedded app's identity, both executable slices and strict signature, and checked the packaged preinstall bytes. macOS Installer's read-only metadata queries returned `RequireLogout` and only `CurrentUserHomeDirectory`. No package was installed and no logout occurred. The full Installer success-screen button, application save/cancel handling, fresh/upgrade installation and post-login input-source registration still need an explicit manual check in a disposable login session, alongside the existing host checks. Developer ID Installer signing, notarization and R2 publication remain unexercised.

The package uses Swift Testing for ambiguity, language filtering, deterministic ranking, deduplication, literal preservation, syllable boundaries, initials, partial input, phrase construction, continuous mixed input, composition edits, and stale selections. Additional targets cover learning feedback, persistent global vocabulary, historical library decay/expiry fixtures, bounded storage, restart, file permissions, malformed data, write failures, deletion ordering, opt-in/pause, secure-event suppression, and settings persistence. These tests do not launch InputMethodKit or register an input source.

`CompositionBoundaryTests` verifies editable ASCII periods under every punctuation policy, default retention of ASCII/Chinese punctuation and symbols, exact domain/email/code spelling across enabled-language sets, caret edits/deletion, explicit literal confirmation, no literal learning, and rejection of obsolete results after edits, commit and cancellation. Optional smart/confirm punctuation and Tab behavior retain separate coverage. `LanguageSettingsTests` checks Keep Composing as the default/fallback and preserves an explicitly saved smart policy. These core checks do not establish native event delivery.

`PinyinPreviewQualityTests` checks `nishuodezhege` in both provisional and final results with Chinese alone and both languages enabled. An isolated lexicon places a high-scored `说` after more than 16 weaker homophones and verifies that preview narrowing does not replace it with `书` + `哦`; reversing source order must retain the same preferred sentence. Run `./scripts/test.sh --filter PinyinPreviewQualityTests` for these regressions.

Chinese dictionary maintenance now uses SI category CSVs with editable integer weights in the fixed shared unit. CSV tests preserve exact text/readings, content-derived tie order and existing exclusions, and validate edits before replacing either runtime dictionary. Historical raw-upstream and sentence-quality records below describe their original implementations; scoring formulas remain unchanged, while equal-weight dictionary ties now use content-derived order. Swift regressions retain coverage for frequency ratios, fractional scores, fallback entries and preview/final consistency. See the latest [verification record](VERIFICATION.md) for checks actually run and remaining quality limits.

`CandidateViewTests.singleLetterCandidateRemainsVisibleAndSelectable` renders the default engine’s `a` candidate in compact and expanded layouts under light/dark appearances, checks that its label is visible and fits, and verifies mouse/number identity. Set `SI_SHORT_CANDIDATE_SNAPSHOT_PATH=/tmp/si-short-candidate` to export light/dark compact images. In a host app, type `a` and `i`, check that choice 1 shows its letter, and confirm it with Space, a digit and a mouse click; repeat after expanding and in both appearances. Automated rendering does not establish live host-event delivery or VoiceOver behavior.

`EnglishSentenceTests` checks continuous English word spacing in final/provisional searches, English-only and combined language settings, casing, completion, deterministic results, exact literals, preserved mixed output, prefix source boundaries and aggregate-only learning. It distinguishes `iwanttobuild` from the missing-letter spelling `iwantobuild`. Run `./scripts/test.sh --filter EnglishSentenceTests` for these regressions.

The `SIPresentationTests` target checks the production selection model and AppKit views: visible digits/highlight, real `NSEvent` key values, last-page bounds, candidate identity, mouse button actions, literal reachability, and prefix/whole commits. It never shows a candidate window or operates another application. For a focused run with the related composition regressions:

```sh
./scripts/test.sh --filter 'CandidateSelectionTests|CandidateViewTests|CandidatePlacementTests|PartialCommitTests|CompositionEditingTests|CompositionBoundaryTests'
```

Set `SI_CANDIDATE_SNAPSHOT_PATH` to an output PNG path to retain the synthetic offscreen expanded view render, with sibling `.dark.png`, `.compact.png`, `.compact.dark.png`, and `.narrow.png` previews. The view fixture uses curated synthetic candidate text to inspect styling independently of decoder ranking. Increased Contrast needs a live system-setting check: on this SDK, constructing a named high-contrast appearance normalizes back to Aqua and does not simulate that preference. This checks view drawing and state, not host key routing, live VoiceOver behavior, automatic system-appearance changes, or candidate positioning. Selection/view regressions cover six-item pages and four-row expanded grids, preserving selection through expansion, reset between compositions, narrow-screen layout, disabled pending expansion, ordinary-budget shortlisting plus all displayable generated dictionary characters with language/literal reachability and ignored wheel/trackpad events, engine-relative order across constructed hypotheses and words, consumed-spelling learning scores, and prefix remainder commits. The window applies its four-hypothesis/word-tail policy; scores themselves remain unchanged.

`SequentialWordSelectionTests` verifies `biruzhege` in Chinese-only/bilingual searches, provisional/full results and both layouts: all retained choices preserve engine-relative order, constructed choices share the four-hypothesis limit, every page number matches its candidate, and choosing `比如` consumes only `biru` (including apostrophe-aware boundaries). The synthetic interleaved head and bilingual `hei` regressions verify that lower-ranked mixed fragments never move ahead of `黑`, and fragments outside the ranked head do not backfill word positions. `FirstWordPrefixTests` covers crowding, the ordinary 27-choice budget with additional character retention, retained language identities/literal, the decoder's independent 24-word pool, consumed-spelling learning and lexical evidence. Offscreen view tests render actual pages in light and dark appearances; set `SI_WORD_SELECTION_SNAPSHOT_PATH=/tmp/si-word-selection` to retain the first/second `biruzhege` pages. These checks do not establish live host routing, VoiceOver or positioning.

`CandidatePlacementTests` checks synthetic host geometry separately: inline-session coordinates taking priority over displaced document geometry, recovery from a cached document fallback, actual-range validation and ambiguous-origin corroboration, UTF-16 offsets after supplementary characters, invalid/unavailable marked ranges and rectangle fallback, fresh geometry after reflow, composition-start queries, caret fallback, composition-local cached coordinates, invalid/missing coordinates, edge clamping, left/above displays, and display removal. It does not exercise InputMethodKit's actual coordinate delivery.

`EnglishVocabularyTests.technologyCategoryAddsTermsAndPreservesBaseCasingAndLiteralInput` covers the SI-authored technology category, including base `ai` versus uppercase input `AI`, new multiword/digit keys, completion, disabled English and exact literal fallback. Category provenance and the CSV checksum are recorded in `Data/Vocabulary/meta.json`.

On November 3, 2026, the 164-row technology category added 13 effective outputs. A source comparison preserved all 74,327 preexisting English outputs, keys and weights. Both CSV dictionary checks, pinned Chinese context verification, all 306 Swift tests (`./scripts/test.sh --disable-sandbox`, because nested SwiftPM sandboxing was unavailable) and the Debug app build passed. Python vocabulary maintenance passed 41 of 42 tests; the existing domain metadata count is 1,209 while its unchanged CSV contains 1,199 rows, so `test_domain_category_is_valid_ascii_without_urls_or_duplicate_outputs` still fails. No installation or live host verification was performed.

`EnglishVocabularyTests` compares direct candidates against a source-list reference, checks technology exact/completion/mixed candidates and disabled languages, checks every English word and every nonempty prefix against the complete vocabulary, verifies cached casing and probability costs, and exercises mixed exact/completion walks with apostrophe boundaries and the two-letter completion minimum. Run it with `./scripts/test.sh --filter EnglishVocabularyTests`. Lexical order, full result ranges, exact literals and language filtering must remain intact.

`WholeWordCandidateTests` checks character-by-character `danci` and `dan'ci` input in Chinese-only and combined-language settings, provisional/final delivery, both panel layouts, score-ranked visibility within the 27-candidate shortlist, exact literals and committed source/text. The Chinese vocabulary regression also checks whole-code frequency ratios, `xian` versus `xi'an`, and deliberate whole-input learning. These checks do not operate a live host.

`CandidateEngineTests` independently covers fractional score ordering across whole/short-prefix/long-prefix candidates, deterministic ties, consumed-spelling learning and an isolated frequency change that moves `比如` above a whole phrase without changing its standalone word score. Synthetic `xianshi`, `biruzhege`, `danci`, `nihaopengyou` and `iwanttobuild` check score order through Chinese-only/bilingual and provisional/full merges. Removal of whole-first ordering exposes short-prefix leaders such as `danci` → `但`; existing sentence/word quality assertions remain active and may fail. Do not hide these results with display quotas or claim a vocabulary-quality improvement.

`XianshiRankingTests` checks `xianshi` and `xian'shi` with Chinese-only and bilingual settings, provisional/full delivery and compact/expanded layouts. `显示` and `现实` must remain on the first page, all retained choices preserve engine score order without reserving whole-word or prefix positions, and numbered confirmation commits the exact word and consumed spelling. Literal fallback and the ordinary-word budget remain intact; generated dictionary characters remain available beyond it. On an intentionally installed build, repeat these spellings in TextEdit and a browser field, confirm `显示` with a number and mouse, and check Escape, shortcuts and focus changes. Automated selection tests do not establish native event routing or VoiceOver behavior.

`MixedWordBoundaryTests` checks intact English versus a split Chinese ending with learning off and injected single-word preferences, including strong/combined preferences, casing, other English words, later continuation, exact literals, deterministic order, explicit apostrophes, and whole/prefix preferences. Run it with `./scripts/test.sh --filter MixedWordBoundaryTests`; fixtures do not read saved user data.

`DeferredCandidateTests` checks edits without synchronous provider calls, immediate literal preservation, stale/out-of-order and cross-client result rejection, cancellation/literal commits, configuration/consent changes, caret edits, and exact prefix resolution. `CandidatePipelineTests` uses controlled continuations to check request coalescing and cancellation/replacement; a production-worker test verifies that providers run off the main thread. Staged-result tests check provisional delivery while a full search is deliberately blocked, duplicate/old/cross-client/configuration rejection, full-before-preview delivery, literal commit without waiting, and full resolution before provisional prefix selection. The view tests check retained rows before hints arrive, replacement by fresh pending hints without shrinking the panel, disabled stale row/page/expansion actions in both layouts, normal interaction on full delivery, and cleanup before a new composition; removed-row actions are also rejected. These checks do not exercise InputMethodKit's real event loop. Run `./scripts/test.sh --filter 'DeferredCandidateTests|CandidatePipelineTests|CandidateViewTests'` for the focused regressions.

`benchmark.sh` emits Release-mode JSON for twenty-five synthetic search scenarios with a full 5,000-entry learning profile and 1,000 personal phrases. Cases include all matching personal prefixes, dense 64-letter input, unknown tails, repeated expansions of approximately 1,000-byte phrases, relevant learned tokens, and long Unicode/emoji phrases. `--resources` builds the executable, then uses macOS `time -l` to report process resource usage separately on stderr. JSON records maximum phrase size and a stable, noncryptographic fingerprint of synthetic candidate identity/order, scores, completion/prefix flags, and personal/verbatim flags. Fingerprints are computed outside timed regions; compare them as regression evidence, not as proof over all inputs. Retain machine/OS and iteration details when comparing results. These are in-process engine timings and CLI-process memory, excluding InputMethodKit, UI, IPC, storage, and host-app latency; they do not prove production vocabulary performance.

Two additional measurements compare all edits in a 16-character synthetic burst using synchronous and deferred sessions (3 warmups, 20 measured bursts each). Deferred final search is performed outside the timed edit region; both final candidate fingerprints must match. This measures the caller's edit work, excluding the worker queue, candidate delivery, UI, and confirmation-boundary waits. The twenty-five standalone search scenarios retain 10 warmups and 200 iterations each by default. `SI_BENCHMARK_ITERATIONS=10 ./scripts/benchmark.sh` is an explicitly smaller smoke run (one warmup); it is not equivalent evidence to the full distribution. The two typing-edit comparisons retain their existing three warmups and twenty samples. Five search scenarios exercise English-only broad, ordinary, uppercase, exact and absent prefixes. The report also measures the engine constructor once per process; lazy dictionary preparation occurs during warmup and is outside that constructor sample. Neither measurement establishes app startup latency. Run benchmarks after builds/tests finish so compilation does not compete with measurement.

`./scripts/benchmark.sh --previews` measures the eighteen bounded provisional-search scenarios only, using the same synthetic profiles/dictionaries, ten warmups and 200 iterations. Each scenario freezes one request before timing. These results exclude worker scheduling, full-search contention, UI delivery and host-app events; narrower provisional coverage is not equivalent to final candidate output.

The app build validates the SwiftUI, AppKit, and InputMethodKit integration against the active SDK. Run core tests and app builds locally; GitHub Actions retains only the website workflow.

Release signing discovery checks cover a unique complete same-team pair among unpaired certificates, missing/ambiguous pairs, explicit signer filtering, profile overrides, inaccessible Keychain, and unsigned local/offline explicit dry-run behavior. On October 20, 2026, all 157 shared-core and 35 script tests passed, along with Debug/Release builds. `./scripts/release.sh --arch arm64 --dry-run` successfully discovered the local complete pair and printed the Caterm profile defaults without building, signing, notarizing or uploading. Notarization-profile/team association and live publication remain unverified; the working tree still contains unrelated uncommitted work.

Certificate-policy correction on October 20, 2026: 36 script tests and 157 shared-core tests passed, with successful Debug/Release builds. Discovery now selects the Application using `codesigning` policy before querying a same-team Installer with `basic` policy; a regression fixture ensures a basic-only pair from another team cannot replace that choice. The local release dry-run correctly stopped at a missing Installer identity for the selected valid Application team, before any build, signing, notarization or upload. No Keychain items were modified or deleted.

Release-version fixtures use isolated temporary Git repositories to verify patch increments through `0.0.9` → `0.0.10`, synchronized Debug/Release build counters, version-only commits and matching source revisions, dirty/untracked-source rejection, commit-hook failure recovery, dry-run isolation, pending-release retries, interruption recovery after the version commit, preflight failure preservation, and same-version cross-architecture publication with `--no-bump`. Mocked publication verifies that a failed upload reuses the version/revision and a later new release increments again. On October 20, 2026, all 48 script tests and 157 shared-core tests passed; Debug/Release builds passed. Version commits occurred only in temporary test repositories. This checkout's version was not incremented, and no real release, notarization or upload was performed.

## Software update verification

Script fixtures cover appcast build/display versions, the app-only archive URL/signature/size, invalid signatures, key mismatch, nested helper signing order, public-artifact failure isolation, newer/conflicting/malformed feeds, concurrent feed advances, ETag promotion and identical retries. They never use a real signing key or contact Apple/R2. Run `python3 -m unittest discover -s Tests/ScriptTests -v`, both app build configurations, and a release dry run with explicit synthetic certificate names. Inspect the built `Contents/Info.plist` for the correct SI feed/key and disabled automatic checks/downloads/profile submission; confirm Sparkle.framework and its helpers are embedded, its notice is bundled, and staged nested signing passes `codesign --verify --deep --strict`. An unsigned build cannot establish signed update installation behavior.

In a disposable login session with an intentionally installed, signed Release build and two published synthetic test releases, check Settings and the SI input-menu action with keyboard/VoiceOver, light/dark appearance and long version text. Debug/uninstalled copies must explain why checking is disabled. Closing Settings must leave typing working. Launch/typing must generate no update request until Check for Updates is chosen. Confirm no-update, malformed/unreachable feed and bad-signature errors, cancellation, repeat checks, and the available-update flow. Inspect requests using only synthetic input; they must contain no composition, phrase, learning or host-document data. Exercise Universal and CPU-specific feeds, comparing the integer build counter with the displayed marketing version.

Finish composition/save work before choosing Install. Check pending learning/phrase writes survive normal termination, a single SI process restarts, enabled input sources/settings/phrases remain, and the installed path stays `~/Library/Input Methods/SI.app`. Confirm input in TextEdit, a browser, Terminal and an editor, then focus changes/shortcuts. Record whether log out/back in was needed for registration or resumed typing; do not force it. Cancelled updates must preserve the existing installed bundle. This app-bundle path does not use the pkg's backup/Log Out screen. Keep the previous DMG for recovery and verify reinstall through the ordinary guarded installer in the disposable session. Do not install, publish, stop the user's running SI or log out as incidental automated validation.

## Language-labeled punctuation candidates

Run `./scripts/test.sh --filter 'PunctuationCandidateTests|CompositionBoundaryTests|CandidateViewTests|LanguageSettingsTests'`. Synthetic cases cover `, . / ; ' "`, default-off generation, persisted independent settings, pending-result invalidation on toggle, enabled-language filtering, unique identities, exact original spelling, complete-word punctuation, retained Pinyin separators, domains/code, bounded repeated punctuation/output, personal/verbatim archive exclusions, no vocabulary/context training, stale results and preview/full delivery. AppKit view checks verify visible E/C/A badges immediately after the candidate text, separate glyph/label frames, exact numbered commits and light/dark offscreen rendering in both layouts. Set `SI_PUNCTUATION_SNAPSHOT_PATH=/tmp/si-punctuation` to write those synthetic snapshots.

On an intentionally installed build, verify Settings → Typing → Show punctuation candidates starts off and remains off after restart. With it off, common punctuation outside composition must pass through immediately without a candidate window; trailing punctuation must not produce language variants or show language badges. Turn the switch on and restart to check persistence. While punctuation search/preview work is pending, switch off and verify stale results cannot restore variants, marked spelling/caret remain intact and old selections cannot commit a symbol replacement. Confirm the separate punctuation policy and language/learning choices are preserved.

With the switch on, use TextEdit, a browser field, an editor and Terminal. Start each `, . / ; ' " : ! ? ( ) [ ]` from an empty composition and check English/Chinese alternatives with small E/C badges plus A (As Typed), enabling each language alone and disabling both. In both layouts confirm using Space, numbers and mouse: insert the chosen mark exactly once, without a trailing space or language label, and retain host focus. Check Return preserves exact spelling, Escape cancels, and shortcuts/focus changes cannot commit a stale choice. With Keep Composing, try `nihao,` and `nihao.` followed by explicit candidate selection, then repeat while continuing `nihao.test`, `example.com`, `user@example.com` and `foo/bar` without selecting punctuation. Check `ni'hao` retains its separator and edits around punctuation refresh candidates. Repeat with the optional confirmation policies to retain their existing delimiter behavior. Check that each E/C/A letter is centered inside its badge in both layouts. Verify VoiceOver announces punctuation language/selection and labels remain legible in both appearances and Increased Contrast. Core and offscreen checks do not establish native event routing, host compatibility or spoken VoiceOver behavior.

## Manual input-method verification

Install with `./scripts/install.sh`, log out and back in if needed, add SI in Keyboard settings, and select it. Do not run a second copy from Xcode while using the installed input source.

- Stop any Xcode run before installing. The installer should report both `Installed:` and `Verified: one selectable SI keyboard input source (com.caterm.inputmethod.si)`. A copied/signed app alone is not registration evidence. Registration must leave the current and enabled input sources unchanged.
- The default installation must build/sign the Release product. Use `./scripts/install.sh Debug` only for intentional debugging; preserve the running-process guard and backup/rollback behavior in both configurations.
- For explicit stop-and-reinstall verification, finish any composition, select another input source, stop any Xcode run, then run `./scripts/reinstall.sh` (or `Debug`). Check SIGTERM precedes any needed SIGKILL, installation/registration succeeds, and enabled/selected input sources and saved settings remain unchanged. A process that restarts during the build must still trigger the installer's guard. This check stops SI and installs an app; do not run it as incidental test setup.
- Run `xcrun swift scripts/register-input-source.swift --check "$HOME/Library/Input Methods/SI.app"` to query only SI's registration without enabling or selecting it. Close and reopen System Settings before falling back to logout if its input-source picker is stale.
- Find SI under **English** in the input-source picker. The registration check must report English as the primary discovery language. With both languages enabled, verify `he` and `nihao` still offer Chinese and English matches as applicable; the system category must not filter SI's enabled providers. Existing SI sources keep the same identifier when this discovery category changes.
- For an upgrade from `com.caterm.si`, verify the prior app is backed up, language/punctuation/learning-consent choices are preserved, and saved phrases/learning remain available. Check both initially disabled and explicitly enabled learning consent. A stale manually added source needs removal/re-adding by the user.
- Verify Xcode's `--settings` launch and the installed input menu can show Settings after the background declaration; closing Settings must keep the input-method server alive.

- Open SI Settings from the input menu. Both languages should initially be enabled.
- Type `gm`, `gmail`, `GMAIL`, `github`, `openai`, `chatgpt`, and `nihaogmail`. Verify canonical names, uppercase input, mixed output, literal preservation, paging and enabled-language filtering. Check `may` remains lowercase and Return preserves the exact spelling. Try a synthetic unknown tail such as `nihaogmailQzXvJk`; any path retaining unrecognized text must stay excluded from learning/context.
- Type `subtitle`, `SUBTITLE`, `subtit`, and `nihaosubtitle`. Verify exact/completed English candidates, preserved capitalization, mixed output and the exact literal candidate. Try a broad prefix such as `a` and confirm native paging can reach the original text. Check Return, punctuation and application shortcuts with the expanded vocabulary.
- Type `zimu`, `shujuku`, `rengongzhineng`, and `zimusubtitle`; verify imported Chinese words, mixed output, exact spelling, disabled-language filtering and numbered paging. Compare `xing` and `hang` for `行`, and `lü`, `lv`, `lu:` in core tests. With synthetic `le` → `了` learning, `nihaotitle` must still prefer `你好 title` over both English and Chinese-abbreviation splits. Check the broad prefixes `a`, `y`, and `sh` for paging and responsiveness.
- Type `nishuodezhege`, pause, and verify `你说的这个` is among the first two whole candidates with learning paused, both during initial hints and after final delivery. Repeat with Chinese alone and both languages enabled, then check prefix selection, exact Return spelling, focus changes, and shortcuts. This is a spelling/segmentation check, not proof of grammatical ranking or support for the transposed spelling `zehge`.
- Type `iwanttobuild`, `openthefile`, `helloworld`, `IWANTTOBUILD`, and `iwanttobuil` continuously. Check English word spaces, casing and the explicit incomplete-ending status, both in initial hints and after final delivery. Repeat with English alone and both languages enabled. Space/mouse/digits must commit the exact spaced candidate; Return must retain exact unspaced input. Confirm the prefix `I want to build` in `i'want'to'buildnihao`: only the source prefix commits, without a trailing space, and `nihao` remains editable. Check mixed `helloworldzhongwen`, shortcuts, punctuation and focus changes. The spelling `iwantobuild` must retain its original literal and is not automatically repaired by this lexical segmentation.
- Type `shi`. Verify Chinese candidates, English completions, and original input coexist. Page to the original input if needed; each expanded page must contain at most four rows of six choices, with further pages for retained dictionary characters.
- Type `he`. Verify the English exact match and the Chinese alternatives are both available.
- Commit `nihao` as `你好`, then `world` as `world`, without changing any language setting.
- Enter `nihaoworld`, `hellozhongwen`, and `woaiSwiftshurufa`; verify mixed candidates, preserved English casing, literal fallback, and Space behavior at the end of each language.
- Compare `xian` with `xi'an`; only the latter must exclude the single-syllable `先`. Check a trailing apostrophe does not complete across a syllable boundary. Check `niha` for incomplete spelling, `srf` for stored-phrase initials, and `nhao`/`ni'h` for mixed full/initial spelling.
- Enter `nihaowor`; inspect both known-word completion and Chinese + As Typed alternatives. Use a synthetic unknown span with uppercase letters and verify verbatim characters/case survive. No candidate containing a verbatim span may train learning or become previous-word context.
- Enter `nihaopengyou`, navigate to the prefix `你好`, and confirm with Space and separately native/number selection. Only its source prefix should commit; the rest must remain marked, editable, and offer `朋友`, without an extra space. Return must insert the exact remainder; Escape must discard it. Test source offsets with apostrophes and unit fixtures for ü/u: normalization.
- Disable Chinese. Verify Chinese candidates disappear while English and literal candidates remain.
- Disable English as well. Verify text remains available as typed. Re-enable both languages.
- Use Space, Return, number keys, arrow/page navigation, Delete, and Escape. Wheel and trackpad scrolling must not change candidate pages or selection in either layout. Check the behavior against README.md.
- Enter `shi` and verify collapsed Left/Right selects candidates, the first Down expands the grid, and expanded arrows move by row/column, and Space commits the highlighted candidate exactly once. Press 2 in a fresh composition and verify the second visible row commits without inserting the digit. Page down or use an expanded page button, then press a number and verify it selects that visible row rather than a row from the beginning of the list. Check an absent row number on a short final page does not commit another choice. Outside composition, digits/arrows/page keys must reach the host normally; command/control/option shortcuts must keep literal passthrough.
- Rapidly type synthetic `woaiSwiftshurufa` and a longer repeated spelling; marked text must continue updating while candidates are pending. The panel must stay visible without per-key disappearance or size collapse. While a slow full search is pending, verify provisional hints follow the current spelling instead of remaining on an older word; final candidates may reorder or expand those hints. Compare gradual and rapid typing with `nihaopengyou` and `nengxiangbanfayouhuama`. Try clicking old rows and page controls while pending: they must not commit or navigate. Scrolling must not navigate during or after the search. Check the first composition shows its own literal placeholder, and cancellation/focus changes still dismiss the panel. Immediately try Space, digits, arrows/pages, punctuation, Return, Escape, and a shortcut: selection boundaries must use current candidates, and literal/cancel actions must not restore delayed text. Start another composition and change focus while work is pending; old results/rows must not reappear. Test language, learning/clear, personal-phrase, and secure-input changes during a pending search. Check prefix remainder confirmation and page/digit mapping again after delivery. Record any remaining candidate delay or synchronous confirmation wait separately from marked-text responsiveness.
- Check SI's top menu-bar icon separately from the expanded input menu and system input-source picker. Verify a rounded filled badge with legible SI cutouts on standard/Retina displays, light/dark menu bars, and pressed/selected rows. `InputSourceIconTemplate.tiff` must contain 16×16 and 32×32 pixel representations, each with a 16×16 point logical size; its alpha mask must have transparent letter interiors inside the opaque badge. The built bundle must set `TISIconIsTemplate` to true and reference this resource without an alternate color bitmap. Regenerate with `xcrun swift scripts/generate-icons.swift` after generator changes. After installation, a SI-only `kTISPropertyIconImageURL` query can distinguish the new template resource from a still-registered older filename; it does not prove that a menu agent has refreshed its image.
- Type `niho` with candidates collapsed, move Left, and insert `a`; check that the marked composition becomes `nihao`, with the caret before its final `o`, and `你好` is offered. Exercise Home/End and Forward Delete without moving the host-document caret. Up/Down and page keys must still navigate candidates.
- Expand candidates for `shi`. Left/Right changes columns; Up/Down changes rows without turning the grid page. Use Page Down/Page Up or the footer controls for whole 24-choice pages. Check row/page boundaries, short last rows, all retained single-character alternatives on later pages, exact numbering, Space/digit/mouse confirmation and unchanged marked spelling. Collapse and verify Left/Right still selects candidates; Home/End edits the composition caret. Repeat pending results, focus changes, two hosts and VoiceOver. Outside composition navigation reaches the host, and command/control/option shortcuts retain literal passthrough.
- Enter an identifier such as `MySwiftType` and commit with Return. Verify case is preserved.
- Start with Keep Composing (the default). Type `nihao,world`, `user@example.com`, `foo/bar`, `My_Type+=Value`, and Chinese punctuation: all symbols must stay in the marked spelling without candidate confirmation. Move the caret across a symbol, insert/delete on both sides, then test Return, Space, literal candidate selection, Escape, focus changes and shortcuts. Repeat with languages disabled. In the optional Smart Chinese Punctuation and Confirm Candidate modes, `nihao,` should still confirm `你好，` or `你好,`. Verify saved explicit policies survive restart; unmapped symbols outside composition pass through, while mapped punctuation opens candidates when a language is enabled.
- Under every policy, type synthetic `nihao.test`, `shi.example.test`, and `MyTool.test`; each ASCII dot must remain marked and editable, exactly once, without automatically confirming a Chinese/mixed candidate or converting to `。`; explicitly selecting a punctuation candidate may choose `。`. Repeat after navigating to a candidate and while searches are pending; `.` must not wait for candidate resolution or restore old rows/text. Delete the dot to recover ordinary lexical candidates, reinsert it, then check Return, Escape, focus changes and shortcuts. In Keep Composing, fullwidth `。` also stays editable; in the two optional confirming policies it can still confirm `你好。`. Check Tab/Space/digit/mouse confirmation separately. Digits remain candidate shortcuts; these checks do not establish unrestricted numeric URL/email entry.
- In the optional confirming policies, verify unselected English words/completions remain editable on punctuation and literal on Tab; actively choosing an English candidate permits confirmation. Incomplete personal codes must stay literal until explicitly chosen. Prefix candidates must not be confirmed by punctuation. Check mixed candidates ending in each language.
- Enter a URL, identifier, code separators, numbers, and Tab; verify literal spelling and application shortcuts survive boundaries. Delimiter commits must not train or retain previous-word context.
- Start composition and click elsewhere or change focus. Verify the original text commits once and the old candidate window closes.
- Close and reopen Settings. Verify language preferences survive a process restart and closing the window does not terminate the input method.
- Exercise two applications in succession to check that composition state does not leak between clients.
- Check candidate positioning near screen edges, on multiple displays, in dark mode, and using VoiceOver.
- In a browser or chat composer, type synthetic `nihaopengyou` at the beginning and after existing text (including an emoji). Verify the compact panel stays directly below the marked start, or above it near the bottom edge, instead of drifting far to the right. Continue until the composition wraps, move Home/End, resize/move the host window, and expand/collapse candidates. Repeat after a prefix commit, Escape, focus changes and a new composition. Check TextEdit too, including a host that lacks document-range geometry if available; legacy inline fallback must still position correctly. Record the host/version and actual result; synthetic geometry tests do not establish this live behavior.
- In a browser address field and a plain text field, enter a long synthetic composition such as `nixiangyaoworld`. Verify the panel tracks its beginning rather than jumping to the screen center as input grows. Check Left/Right editing, prefix confirmation, cancellation, and focus changes; a new composition must not reuse another composition's position. Test standard/Retina displays, including a display arranged to the left or above the primary display and insufficient space below the input.
- Check that normal rows show numbers and candidate text without language descriptions. In the single line, check small arrow/pin/text symbols instead of long metadata labels; expanded prefix rows omit `First N` labels. Tooltips and VoiceOver must still identify exact prefix consumption, candidate language and source. Check that the peach selection pill stays close to its text even when a pending window retains extra width, the selected number is orange, and light/dark/high-contrast text stays readable. Start a composition and verify one horizontal line, numbers 1–6, and an accessible expansion chevron. Press Down Arrow or the chevron to expand to four rows of six choices, navigate to a later candidate, then collapse; the highlighted candidate and Space/mouse/digit confirmation must agree with its new visible number. Page keys must change six-choice collapsed pages or whole 24-choice expanded pages, with digits 1–6 applying to the highlighted row. Expanded page buttons must agree. Check mouse-wheel and horizontal/vertical trackpad gestures, including momentum: the highlighted choice and page must remain unchanged. Expanded multiple pages expose page count/previous/next controls; a single expanded page keeps the collapse control. Check clipped long mixed labels, narrow screens and both system appearances. Finish/cancel or switch focus and verify the next composition starts collapsed. Pending searches must keep the old layout/size and disable expansion/actions.
- With learning paused, enter `abilit`; confirm complete `ability` remains among the first five through hints/full results and both layouts. Verify Space, digits and mouse commit the word, while exact `abilit` remains reachable.
- With learning paused, enter `danci` and `dan'ci` in Chinese-only and combined-language settings. `单词` should remain first through initial hints and full results in both panel layouts; Space/1/mouse confirmation should insert exactly `单词`. Confirm `单次` and the original spelling remain available within the panel shortlist; other enabled-language choices qualify by score.
- With Chinese and English enabled, type `bufenci` in TextEdit and a browser field. In provisional/full results and compact/expanded layouts, the first four choices should be `部分词`, `部分次`, `部分此`, `不分词`; a low-ranked English leader must not displace the fourth choice. Verify number 4 and mouse selection commit exactly `不分词`, then check prefix remainders, Return, Escape, shortcuts, focus changes and VoiceOver. Original spelling remains selectable. Automated session/offscreen checks do not establish live host behavior.
- Enter synthetic `biruzhege`, `nengxiangbanfayouhuama`, `nihaopengyou` and `sheguofennudehai`. Verify the first four ranked choices may contain both constructed hypotheses and words; subsequent ordinary choices are single characters/words. Single-language and mixed hypotheses share the same ranked-head eligibility without language reservations. Mixed candidates have no display reservation and must qualify through their effective score in the first four ranked choices. Extra sentences and multiword fragments must not fill later pages. Low-ranked language leaders must not displace any of the first four ranked hypotheses. Check Space, digit and mouse word selection in both layouts: only consumed spelling commits, the exact remainder stays editable and no space is appended. Check apostrophe boundaries, disabled languages, optional vocabulary learning, literal Return, Escape, editing, focus changes, preview/full delivery and VoiceOver. Word-led `ling`, `xianshi`, `danci`, `abilit` and exact English lookup retain their ranked word alternatives. The engine retains its full results; the display policy does not validate sentence meaning.

Run relevant cases in TextEdit (plain text), Safari or Chrome text fields, a code editor, Terminal, and office apps. Check secure text fields using dummy data only; macOS may choose a different input source for those fields.

Record the macOS version, host application/version, enabled languages, synthetic input, expected behavior, and actual output. System registration, key routing, actor-boundary assumptions, and host-app compatibility require this manual verification before release.

## App vocabulary

Use a dedicated synthetic profile on an intentionally installed copy; do not run built and installed input methods together or clear real personal data as preparation. Settings calls this **Personal Learning**, with no per-app learning controls.

1. Confirm learning starts off. Enable **Enable Personal Learning**, select a nonfirst `shike` candidate in TextEdit, then type the identical spelling in TextEdit and a browser/editor: the remembered candidate must be the first ordinary choice. A deliberate different selection must replace it everywhere, including after restart. Explicit personal-phrase pins keep priority. Other enabled-language choices and exact original input remain available.
2. Accept the first choice using Space, number 1, mouse and navigation away/back: usage rises, but frequency strength, correction count and remembered choice do not. A later page's first cell still counts as nonfirst. Every third deliberate nonfirst selection earns one additional frequency point up to 32. Exact first-choice placement works after the first correction, separately from that bonus. Test both provisional and full delivery and compact/expanded pages.
3. Check exact normalized spelling (case and ü/v/u: aliases), explicit apostrophe boundaries, shorter input and a longer pending suffix. Only the exact remembered whole spelling gets forced placement. Select a prefix, then confirm its consumed spelling alone is remembered; its pending remainder must never be saved or pinned. Automatic, delimiter, punctuation, literal and personal/verbatim commits never train. Return and shortcuts retain their existing exact-spelling behavior without duplicate commits.
4. **Manage Learning Data…** searches global words/input, forgets entries and clears all learned vocabulary. Forgetting a selected entry restores ordinary ranking. Explicit phrases remain. There must be no application picker, app discovery or per-app pause/delete/clear controls. Seed the retired `applicationMemory.vocabularyExclusions` key and confirm startup removes it without changing the global learning switch or limiting suggestions. Check off/on consent, the separate direct-input feature, secure input and disabled languages. Changes during pending work must invalidate stale results/clicks. Restart preserves global consent.
5. Use synthetic archives only. Schemas 1–3 atomically become global schema 4 without app identifiers or history. Equal spelling/language/output rows merge bounded counts and maximum strength; schema-1/2 ambiguous strengths/corrections reset, while schema-3 evidence remains. Old last-use times must not create exact-choice markers. Old records still in the file survive age changes, and newer schema-4 selection markers persist across restart. Corrupt JSON/vocabulary/unsupported schemas must preserve original bytes; check migration-write and clear/retry errors and that older queued writes cannot undo deletion. The separate retired shared archive remains untouched.
6. Advance a synthetic clock by at least a year: global records, selection markers and frequency bonuses remain unchanged. Exceed 5,000 records and verify deterministic least-recently-used capacity eviction, including removal of selected/token effects for evicted rows. Forget and clear must still remove records across all apps. This is no age expiry, rather than unbounded storage.
7. Check English/Chinese interfaces, keyboard navigation, VoiceOver, empty/search results and light/dark appearances. No retired history/previous-word controls or app-filtered vocabulary counts should appear. No document, clipboard, URL, recipient or passthrough text is collected.

`ApplicationVocabularyLearningTests` covers one-correction exact placement in final/provisional results, normalization/separators, consumed-prefix boundaries, replacement even with equal timestamps, neutral default acceptance, language/mixed identity, explicit pins, no decay/expiry, bounded rewards and exclusion/deletion. `ApplicationMemoryStoreTests` covers schema-1/2/3 merging, retired-field/app-identity removal, old-record retention, restart/permissions, malformed-file preservation and revision-ordered deletion. `ApplicationMemorySettingsTests` covers global snapshots/counts, independent consent, retired-exclusion cleanup, secure-input suppression, deletion, persistence and obsolete-result rejection. `CandidateLearningTests` retains number/mouse/navigation/page confirmation coverage. Core `LearningProfile` fixtures keep the optional historical decay/context API; those fixtures do not enable age expiry or previous-word learning in the app.

On November 1, 2026, `./scripts/test.sh --disable-sandbox` passed all 415 Swift tests (299 core, 90 presentation, 16 settings, seven storage and three localization), and `./scripts/build.sh` passed the Debug app build. Both localization tables passed `plutil -lint`; changed Markdown local targets and `git diff --check` passed. The ordinary test invocation could not start SwiftPM's nested sandbox in this environment, so the documented fallback was used. Xcode required ordinary cache-directory access outside the workspace sandbox. No input method was installed or personal archive changed. Native host behavior, Personal Learning Settings keyboard use, live VoiceOver and appearance remain unverified.

## App vocabulary ranking checks

The current global profile uses two independent signals: immediate exact-spelling last-choice placement and capped frequency rewards for whole/prefix/eligible-token ranking. Adding a suffix must remove forced placement while preserving the consumed prefix's ordinary capped score. Repeated first-choice acceptance must not refresh the selection marker or strengthen the profile. A different nonfirst selection replaces the remembered choice immediately, even if the two events have identical timestamps. Deletion must not revive an older selection marker.

Use `./scripts/test.sh --disable-sandbox --filter 'ApplicationVocabularyLearningTests|ApplicationMemoryStoreTests|ApplicationMemorySettingsTests|CandidateLearningTests|PrefixLearningTests'` for focused synthetic checks if nested SwiftPM sandboxing is unavailable. Run the full shared suite and Debug app build for implementation validation. Automated tests do not establish native InputMethodKit event delivery, host compatibility, Settings keyboard use, live VoiceOver or secure-field detection.

## Input History

Use a dedicated synthetic profile and an intentionally installed build; never record private text or install a second SI instance as incidental verification.

1. Confirm **Input History → Save Input History** starts off independently of Personal Learning and all retired history flags. Enable it alone and submit `nihao` → `你好`, English candidates, Return-literal `Hello`, personal phrases and punctuation. Each successful SI submission must create one row with exact original spelling/output and time. Repeating the same submission must create a different record. English auto-space and SI punctuation replacements belong to output; keys passed through outside composition do not.
2. Confirm a Pinyin prefix with ü/u:/v aliases and explicit apostrophes: save only consumed original spelling, never normalize displayed history or include the pending remainder. Automatic prefix commits create separate rows, and the later remainder commit creates another. Cancel/edit without submission, Return outside composition, direct-input apps and another system input source must not record. Test Space, number, mouse, Return, delimiters, focus and shortcuts for unchanged insertion/commit behavior and no duplicates.
3. Check secure input before/after host calls and off/on consent changes during pending/reentrant work. Recording must be suppressed without reviving stale consent. Neither history consent nor viewing/searching history enables learning. Disable history, finish accepted writes, restart and inspect retained rows without recording new ones. No clipboard, document, URL or raw event data is queried.
4. View, search literal substrings (including SQL punctuation), page backward/forward and Refresh in English/Chinese UI, light/dark appearance, keyboard-only use and VoiceOver. Each page has at most 100 rows. New submissions and backward clock changes must not duplicate/skip older keyset pages. Test deletion while search/page requests are pending; late reads cannot restore deleted/cleared rows.
5. With synthetic data, exceed 5,000 rows and use timestamps many years old: history must retain all rows without age/count eviction. Delete one row, clear while writes are queued, and restart; nothing deleted may return through a stale insert or retry. Learning, explicit phrases and retired archives stay unchanged. Do not clear real archives as preparation.
6. Test corrupt JSON-like bytes, unsupported SQLite user_version, invalid schema, write errors and limited disk access using temporary synthetic stores. Original corrupt/unsupported bytes remain untouched. Errors pause recording, retain accepted failed records in memory for Retry Saving History and expose reopen/clear recovery. Retry the same event twice without duplicates. Clear removes the history database and sidecars; backups/forensic remnants are outside these controls. Normal termination drains accepted queued writes; forced termination and unretried errors can lose unsaved entries.

`InputHistoryStoreTests` covers 5,005 old/repeated records, exact Unicode/NUL bytes, retry identity, sequence pagination under newer/backdated inserts, parameterized substring search, permissions, independent deletion/clear, invalid batches and corrupt/unsupported preservation. `InputHistorySettingsTests` covers independent consent, old-flag isolation, consumed-prefix/source/output boundaries, secure-input suppression, consent-generation rejection, queued-clear ordering, deletion and failed-write retry. These synthetic checks do not exercise native host reentry, secure fields, Settings keyboard/VoiceOver or actual appearance; those remain manual.

On November 1, 2026, the Input History change passed `./scripts/test.sh --disable-sandbox` with 422 Swift tests (299 core, 90 presentation, 19 settings, 11 storage and three localization), plus `./scripts/build.sh` for the Debug app. Both localization tables passed `plutil -lint`, all Input History UI keys had translations, local Markdown targets and `git diff --check` passed, and `node scripts/build-website.mjs` built the English/Chinese home, Privacy and Terms pages. The nested SwiftPM sandbox was unavailable, so the documented fallback was used; Xcode required standard cache access outside the workspace sandbox. No input method was installed, no real input was recorded, and no personal archive was opened or changed. Native InputMethodKit host behavior, secure-field/reentrant callback behavior, Settings keyboard/VoiceOver and live appearance remain unverified.

### Input History export and receiver tools

Use synthetic archives and explicit temporary destinations. Verify **Export Input History…** in both the Settings section and history manager. The action must open the save panel directly, disclose private source/output/time and offer no backup/training choice. Cancel the save panel without creating a file or changing recording consent. Choose a JSONL destination and replace an existing export intentionally; failures must preserve it. Test keyboard-only operation, English/Chinese, VoiceOver and both appearances. No network/share action occurs.

Export with a search hiding all rows and on a later page: the file must contain every saved row in sequence order. Pending writes must finish first, unresolved save errors must block export, and normal termination must drain an accepted export. Use exact Unicode/NUL/casing/ü/separator/space fixtures, repeats and more than 5,000 rows. Check permissions, manifest version and absence of purpose flags, summary count/checksum, corruption/truncation/version/duplicate rejection and the Swift-export → Python-restore → native-read round trip. Native history remains unchanged.

Run `python3 -m unittest discover -s Tests/InputHistoryToolsTests -v` in addition to the shared suite. The receiver commands in [INPUT_HISTORY_EXPORT.md](INPUT_HISTORY_EXPORT.md) must refuse existing output paths, restore the ordinary export exactly and accept that same file for candidate preparation. Preparation produces only unsplit/unreviewed candidate CSV plus hashes/filter provenance. Automatic confirmations and literal tasks are excluded by default; an explicit flag admits ASCII literal/copy observations. Do not collect real data, print private text, alter maintained CSVs or start a training run as validation.

On November 1, 2026, the export/receiver change passed 425 Swift tests with `./scripts/test.sh --disable-sandbox` (299 core, 90 presentation, 20 settings, 13 storage and three localization), all four Python export-tool tests, and the Debug app build with `./scripts/build.sh`. The native-export/Python-restore/native-read regression passed using synthetic data. Localization lint/key coverage, changed local Markdown targets, `git diff --check`, and the six-page English/Chinese website build passed. No input method was installed, real history exported, file shared/uploaded or model training started. Export save/cancel dialogs, native accessibility and host operation remain unverified.

On November 1, 2026, simplifying history export to one direct save action passed all 425 Swift tests, four Python receiver-tool tests, and the Debug app build. The export contains no backup/training purpose or permission fields, and the same file passes restore and candidate preparation. Localization lint/key checks, local Markdown targets, `git diff --check` and the English/Chinese website build passed. No input method was installed, real history exported, file sent or training started. Native save-panel/cancellation/VoiceOver behavior remains unverified.

## Automatic prefix confirmation

Run `./scripts/test.sh --filter AutomaticConfirmation` and `./scripts/benchmark.sh --automatic-confirmation`. The benchmark emits paired Release full-search timings with/without evidence, caller-side edit/delivery timings excluding decoding, invariant checks for candidate order/scores/bytes, and fixed synthetic typing traces. It evaluates one-result-per-character, coalesced three-character deliveries and final-only delivery in Chinese-only and bilingual settings. Existing ranking fixtures, including the already inspected historical holdout, are development/regression evidence rather than an independent accuracy estimate. A correct committed prefix with an empty output counts as abstention, not successful conversion; inspect activation and false confirmations separately. Timings are in-process and do not establish native event latency.

On an intentionally installed build, verify the following in TextEdit, a browser text field, a code editor and Terminal. Installation is not incidental setup for this check.

- The Typing toggle is initially off, keyboard/VoiceOver accessible, and survives restart. Ordinary manual Space/number/mouse selection, Return, Escape, focus and shortcuts keep their existing behavior while off.
- Enable the option and gradually type `nihaopengyouxuexizhongwen`. Leading stable words should commit without a space while the ending remains marked, editable and represented by current candidates. Repeat with rapid typing; no dropped/duplicated letters or synchronous full search should be introduced on append or timer delivery.
- Type `nihaopengyou` and wait: `你好` may confirm after at least 1.8 seconds, leaving `pengyou`. Continuing to wait must not drain the rest. Type more to permit another confirmation. `shi`, `he`, `nihao`, short `dishiye`, English and mixed leaders, uppercase identifiers, unknown text and symbol-bearing input must not be forced into a prefix conversion. A pause must not confirm an isolated single-character prefix. Nearby homophones that disagree on the beginning must remain editable regardless of pause length. Repeat `nihaotitle` and `nihaotitlezhongwen` with English disabled; their English spans must still suppress automatic conversion.
- Before a pause fires, delete, move the caret, navigate/page candidates, expand/collapse the panel, press Escape, Return, a shortcut, or change focus. The old task must not insert text or restore candidates. Start a new composition, including the same spelling, and switch between clients; old work must remain invalid. End-of-buffer typing after an edit builds fresh evidence, while middle-of-composition edits remain manual.
- Change languages, punctuation, automatic confirmation, personal phrases, learning consent/clear and secure input while a search or pause is pending. Also toggle a typing setting away and back without another keystroke. Results and timers from the prior configuration must not commit. No language selection or enabled language alone enables learning.
- With a dedicated synthetic learning profile, verify automatic commits neither change saved record count/strength/timestamps nor supply previous-word context. Deliberate selections must still train under the existing opt-in rules.
- After automatic confirmation, Return/shortcuts preserve the remaining original spelling. Confirm Space/number/mouse prefix selection and candidate paging still agree with the displayed rows. Edit already committed text using the host's ordinary controls; automatic restoration of its original Pinyin is not implemented. Check marked UTF-16 selection, candidate positioning, both appearances and VoiceOver after a prefix is inserted.

Core regression tests and a successful build do not establish these native host checks. Record actual host/version, input, committed prefix, editable remainder, timing and any unexpected confirmation using synthetic text only.

## Personal phrase checks

Use synthetic phrases in a test profile. Add `xm` → `测试项目`, choose its language, and verify full-code and prefix suggestions with learning off. Prefer a full-code phrase and verify other languages and literal input remain available. Disable its language and check it disappears.

Enter `woaixm` and verify the saved phrase participates in a longer composition. Confirm it with learning enabled; neither the derived candidate nor its phrase text should appear in learning records or previous-word context. Use isolated fixtures for many colliding codes and long expansions; direct matches/literal fallback must remain available and constructed text must never be silently truncated.

Edit its code/text, delete it, and clear the dictionary; each change must survive restart and must refresh an in-progress composition on the next event. Cancel clear/editor dialogs and verify no unintended changes. Personal phrases must not appear in automatic learning records or become previous-word context.

Export a test JSON file, inspect its fields, then import it with duplicates and different local pin settings. Existing local content wins. Invalid/unsupported/oversized/capacity-exceeding imports must preserve all existing phrases. Cancelling import/export must not show a failure. Check search, keyboard focus, VoiceOver row/button labels, error persistence, retry, and long phrase layout. Native file dialogs and real secure-field suppression still require manual inspection; automated tests cover codec/model/storage behavior only.

## Website verification

For the independent static landing page, use the build, browser, localization, accessibility, and deployment checks in [WEBSITE.md](WEBSITE.md). These checks do not install or exercise the input method.

## Language-specific spelling and bounded search

Run `./scripts/test.sh --filter 'UnifiedRankingTests|SpellingEvidenceTests|UnifiedRankingPresentationTests'` and `./scripts/benchmark.sh --quality`. Fixed regressions cover normalized probabilities, character relabeling invariance, segmentation-independent Chinese spelling costs, English completion and exact literal/commit preservation. The 21 phonetic fixtures report unresolved ordinal/date ambiguities as well as initial and mixed spellings; their expected outputs do not authorize phrase-specific score rules. The historical holdout has been inspected during development and is no longer an independent estimate.

On an intentionally installed build, type synthetic `danci`, `dan'ci`, `dierye`, `nhao` and `abilit` in TextEdit and a browser field. Check actual candidate ranking, select visible alternatives from compact/expanded panels with Space and a number, then exercise Escape, focus changes and a shortcut. Check that learned overrides remain deliberate, paused/secure input disables them, and no previously pending candidate returns after cancellation. A core test/build does not establish these native host checks.

## Candidate font coverage

Run `./scripts/test.sh --filter 'CandidateTextSupportTests|CandidateSelectionTests|CandidateViewTests'`. Coverage checks system fallback for ordinary/extension Han, combining marks and emoji, rejects a guaranteed-missing noncharacter alone or inside a word, preserves exact literal bytes and language identities, and verifies that missing candidates do not consume shortlist slots. The synthetic `heihe` regression checks provisional/full results, compact/expanded numbering, mouse identities and exact prefix commits against the filtered list. Engine results and public dictionary entries remain unchanged.

On an intentionally installed build, type `heihe` in TextEdit and a browser field, expand and page through candidates, and confirm that missing-glyph boxes are absent while supported rare characters remain selectable. Check Space, numbers, mouse selection, prefix remainders, Return, cancellation and focus changes in light/dark appearances and with VoiceOver. Coverage depends on installed system fallback fonts; no extension block is excluded wholesale. Original literal input remains available even if it contains an unsupported character. Automated Core Text and offscreen view checks do not establish live host or VoiceOver behavior.

On October 26, 2026, all 360 Swift tests passed (261 core, 79 presentation, 14 settings, 3 storage and 3 localization), and the Debug app built successfully after adding the font coverage filter. The presentation checks include Core Text shaping and offscreen candidate selection/view behavior. No input method was installed, and live host, VoiceOver and system appearance checks remain unverified for this change.

## Movie vocabulary update, 2007–2026

The [movie maintenance guide](../Data/Vocabulary/MOVIES.md) records the 400-film
selection, language-specific categories, weights, provenance and typing limits.
Run `python3 -m unittest discover -s Tests/VocabularyTests -v` for catalog coverage,
reviewed Pinyin and compiler failure-safety checks, and
`./scripts/test.sh --filter MovieVocabularyTests` for exact title output,
capitalization, numeric spelling, shared title/ordinary-word keys, deterministic
ordering, enabled-language filtering and literal fallback. The existing exhaustive
English trie test now walks stored typing keys, including every title and every
prefix range, rather than inferring keys from displayed text.

On October 28, 2026, all 19 vocabulary Python tests and all 396 Swift tests passed
(288 core, 83 presentation, 15 settings, 7 storage and 3 localization). The Swift
suite used `./scripts/test.sh --disable-sandbox`: the ordinary invocation could
not initialize SwiftPM's manifest sandbox inside the execution sandbox. The Debug
app built successfully with `./scripts/build.sh` using normal Xcode cache access.
The regenerated dictionaries passed `csv_dictionary.py build --check`,
`msime_dictionary.py build --check` (including pinned context) and
`ranking.py --check`. All 429 previous movie rows and reused weights were checked
for preservation; only 212 Chinese and 350 English effective identities are new.
No input method was installed or live host compatibility verified.

On an intentionally installed build, use synthetic input in TextEdit and a browser
with app vocabulary disabled. Check `feichirenshengsan` → `飞驰人生3`,
`nezhazhimotongnaohai` → `哪吒之魔童闹海`, `insideouttwo` → `Inside Out 2`,
`dontlookup` → `Don't Look Up`, and uppercase English input. Confirm titles using
Space, numbers and mouse; spaces, punctuation and digits inside the candidate
must commit exactly once. Return must retain exact typed spelling. Repeat with
one language enabled and with both disabled, and check Escape, shortcuts and
focus changes. Existing short-prefix prediction remains bounded; a long title is
not guaranteed to appear from a short Chinese prefix. These manual checks remain
unverified.

## Basic domain vocabulary

The [domain guide](../Data/Vocabulary/DOMAINS.md) describes 304 complete names in
`english/domain.csv`. All 128 standalone suffix rows from the first draft are
removed. Every remaining reading equals its lowercase text, including dots,
hyphens and digits. `googlecom` is not an alias for `google.com`.

Run the normal vocabulary Python suite and
`./scripts/test.sh --filter DomainVocabularyTests`. Checks cover full-name syntax,
invalid-update failure safety, Chinese reading isolation, literal dotted/hyphenated
and numeric keys, suffix removal, direct/preview completion, casing, language
filtering, determinism and exact literal fallback. The exhaustive English trie
suite walks every stored key and prefix, including domain punctuation and digits.

On October 28, 2026, all 22 vocabulary Python tests and 399 Swift tests passed
(291 core, 83 presentation, 15 settings, 7 storage and 3 localization), using
`./scripts/test.sh --disable-sandbox` for the previously documented SwiftPM
execution-sandbox limitation. The Debug app built with `./scripts/build.sh`.
CSV dictionary checks, pinned Chinese context verification and ranking attribution
checks passed. Logs are under `.build/domain-literal-update/`.

No input method was installed or listed domain contacted during automated tests.
On an intentionally installed build, check synthetic `google.com`, `google.`,
`rust-lang.org` and `mail.163.com` in TextEdit and a browser with app vocabulary
disabled. Check Keep Composing and candidate-confirming punctuation policies;
the latter may confirm before the full dotted name is composed. Number keys keep
the existing selection contract. Confirm using Space, numbers and mouse, verify
normal English spacing, and check Return, Escape, shortcuts, focus changes and
English disabled. These host checks remain unverified; no URL entry mode is added.

## Explicit Cloudflare Radar domain import

The [Radar maintenance command](../Data/Vocabulary/DOMAINS.md#fetch-and-merge-cloudflare-radar)
fetches `ranking_top_1000` only when explicitly invoked, or replays a local CSV
with `--input`. Normal app/package builds remain offline. Tokens are read from
the environment or an ignored dotenv file, are not command arguments, and are
not written to snapshot/provenance files. Redirects are rejected before forwarding
the bearer token. Retained Radar attribution and the full CC BY-NC 4.0 license
are bundled independently of SI's GPLv3 code license.

Run `python3 -m unittest discover -s Tests/VocabularyTests -v`. Synthetic tests
cover exact 1,000-domain validation, malformed/truncated/duplicate responses,
existing row/weight preservation, idempotent imports, original seed retention,
publication rollback, intervening edits, dotenv parsing without shell execution,
missing credentials, redirect rejection and sanitized authentication errors.
The merged category, source snapshot and retained licenses have checksum checks.

On October 28, 2026, all 29 Python vocabulary tests and 400 Swift tests passed
(292 core, 83 presentation, 15 settings, 7 storage and 3 localization). Swift used
`./scripts/test.sh --disable-sandbox` for the documented execution-sandbox limit.
`./scripts/build.sh` completed the Debug app build; ordinary dictionary checks,
pinned Chinese context and ranking attribution checks passed. The initial script checks used synthetic import data. After local Token
configuration, the authenticated API returned 1,000 valid unique domains: 95
overlapped the original selection and 905 were added, for 1,209 total names. All
304 original rows/weights, every fetched domain and a no-write idempotent replay
were independently verified. The snapshot SHA-256 is
`80bcc006b2a6e1d264051f95550e3091fcad1dd31a51e3a50f85695562192faa`.
The updated dictionaries and post-import tests/build are recorded below. Logs are
under `.build/radar-domain-update/`. No input method was installed or host behavior
manually verified.

After the authenticated Radar merge, all 29 Python vocabulary tests and all 400
Swift tests passed again with the 1,209-domain category; the Debug app rebuilt
successfully. Both dictionaries match their CSV sources, pinned Chinese context
and ranking attribution checks pass, and the English manifest records 65,161
effective entries. Source/snapshot/license/import-report files were checked for
accidental retention of the configured Token; none was found. `.env` remains
Git-ignored. No input method installation or native host verification was performed.


## Shared offline model and algorithm evaluation

The [root evaluation registry](../eval/README.md) supplies frozen ranking,
correction and Pinyin-to-Hanzi suites for all model sizes and algorithms:

```sh
python3 -m eval validate
python3 -m unittest discover -s eval/tests -p 'test_*.py' -v
./llm/.venv/bin/python -m unittest discover -s eval/tests -p 'test_*.py' -v
./llm/reranker_small/scripts/check.sh -p test_benchmarks.py
```

Tests cover fixed data hashes/splits, original multi-reference Pinyin rows,
missing-gold/empty ranking pools, language-aware index permutations, exact Unicode
outputs, correction/no-change metrics, full prediction coverage, dataset/scorer
comparison guards and real tiny-checkpoint adapters. The standard-library run
skips optional adapters if PyTorch is unavailable; the shared environment runs
them. The historical ranking builder/evaluator reads compatibility links to the
same relocated files. Use the registry's export/score/compare commands for new
cross-model reports; keep model loss/perplexity separate. These constructed
fixtures have no independent label review, and new training corpora need their
own overlap audits. No offline check establishes native host compatibility.

## Retired AI comparison and host context

The November 4 removal retired the AI comparison row, status and scores, host
context readback, legacy Settings switches and bundled model resources. The
production KenLM ranking below still uses one engine-ranked candidate list.
`LanguageSettingsTests` covers cleanup of all retired AI preferences while
preserving enabled languages, direct-input rules and both recording consents.
Existing candidate-selection and presentation tests cover the engine shortlist,
number/mouse confirmation, neutral first-choice learning and expanded paging.

Run `./scripts/test.sh` and `./scripts/build.sh`. Inspect the built app to confirm
that no Reranker resources or compiled model assets are bundled.

On November 4, 2026, `./scripts/test.sh` passed all 433 tests (301 core,
91 presentation, 25 settings, 13 storage and three localization), and
`./scripts/build.sh` passed the Debug app build. Both commands used normal
compiler/cache access after the agent sandbox blocked SwiftPM/Xcode facilities.
The built app contains no Reranker directory or Core ML model resources. Synthetic
expanded light/dark and narrow candidate renders were inspected; the new compact
regression checks one row and matching engine/number/mouse/accessibility identities.
Localization plist lint, 101 local Markdown targets and `git diff --check` passed.
No input method was installed, replaced or launched. Live Settings/VoiceOver and
interprocess host behavior remain unverified.

Live verification remains required in TextEdit and a browser/editor:

1. Compose synthetic `womenkaihui`, `ling` and `biruzhege`. Verify a single compact
   engine row, no AI badges/status/scores, and the exact literal choice on paging.
2. Verify Down expands the engine grid, Up navigates that grid, Page Up/Down and
   numbers use the current page/row, and mouse/Space confirms the displayed choice
   without taking host focus. Prefix selection must leave the exact remainder.
3. Check Return, Escape, shortcuts, rapid edits, cancellation and focus changes;
   obsolete candidates must not restore old composition or commit stale text.
4. Check Settings has no retired AI comparison or host context controls.
   Languages, direct input, Personal Learning and Input History retain their
   existing settings.
5. Check keyboard use, VoiceOver, light/dark/high-contrast appearance and narrow
   display positioning. In-process rendering does not establish host compatibility.

## Offline KenLM configuration selection

Run `corpus/.venv/bin/python -m unittest discover -s corpus/tests -v`.
Synthetic fixtures check first-occurrence deduplication, stable seeded block
assignment, split counts/disjointness, 100,000-line smoke extraction, query
summary parsing, all-smokes-before-full gating and failure stopping, complete
four-model comparison validation and the size/perplexity recommendation rule.
Real smoke models exercise `lmplz`, quantized trie construction and `query`;
full comparisons verify scored heldout token coverage including EOS, identical
input/tool hashes and matching OOV counts. All commands, options, source pins,
data counts and measured results are in [README_kenlm_train.md](../README_kenlm_train.md).
No native installation or user-data collection is part of this offline workflow.

## Production KenLM ranking

See [the production model record](../README_kenlm_train.md#production-kenlm-ranking)
for the model install command and the train-only benchmark links.
`SI_TEST_KENLM_INSTALLATION` points the full Swift suite to a versioned test
installation. It exercises native scores, cleaning vectors, configuration
load, model-free provisional selection, stale results and automatic-confirmation
confidence checks. Both build configurations use the same preset.

Manual validation in TextEdit and a browser/editor remains pending. On an
intentionally installed build, compare a compatible model installation with
the missing-model fallback. Check that `biruzhege` retains a selectable
`比如` prefix and leaves `zhege` after confirmation. Exercise quick Space
and number confirmation, delayed full results, cancellations and focus switches
while the model opens. Check the opt-in automatic confirmation path and secure
input. Verify candidate order, selection and VoiceOver in both window layouts.
