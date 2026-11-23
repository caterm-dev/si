# Testing SI

Use synthetic input and profiles. Record the SI revision, build resources, macOS
and host versions, enabled languages, and the expected and observed behavior.
Automated checks cover the engine and bridge. InputMethodKit event routing,
registration and live accessibility require host checks in a macOS login session.

## Automated checks

Run these commands from the repository root.

```sh
cargo fmt --all -- --check
cargo clippy --locked --workspace --all-targets -- -D warnings
cargo test --locked --workspace
./scripts/test.sh
./scripts/build.sh Release
python3 scripts/verify-rust-app.py .build/xcode/Build/Products/Release/SI.app/Contents/Resources
```

Use `./scripts/test.sh --disable-sandbox` if the environment prevents SwiftPM's
manifest sandbox from running. For a focused bridge check, use
`./scripts/test.sh --filter RustConversionIntegrationTests`. This covers the same
bridge the app uses, including bilingual results, exact UTF-8 spans, personal
phrases, confirmation evidence and token preferences.
SwiftPM uses a separate dictionary generated from the tracked CSVs.
The Release build and its package check use the locally generated lexicon
and tracked word grams under `Data/Engine/`. The verifier checks the packaged
small reranker and rejects obsolete LambdaRank resources in incremental builds.

Run the synchronous selection and window regression tests with the app's paired snapshots.

```sh
SI_TEST_ENGINE_RESOURCE_DIRECTORY="$PWD/.build/xcode/Build/Products/Release/SI.app/Contents/Resources/SIEngine" \
  ./scripts/test.sh --filter 'SynchronousCandidateTests|WindowRankingRegressionTests'
```

These tests exercise statistical order, spelling suggestions, the candidate
shortlist, the literal fallback and explicit submission. On an installed build, type synthetic `fangan` in
TextEdit after `先定个` and use number or mouse selection immediately. Check
Space, Return and Escape, then type another spelling and switch focus.
Confirm the displayed result belongs to the current composition. With Pinyin correction off and both languages enabled, type
`xiandingge` in an empty field. Confirm that `先定个` and `限定个` remain
selectable after each synchronous update. Repeat in a second supported host
before claiming host compatibility.

Run `cargo test --locked -p si-engine --test conversion` for the bounded search
and `cargo test --locked -p si-cli --test workflow` for snapshot/resource
commands. The CLI fixtures exercise absolute weight updates, same-source
reimports, language-filtered CSV snapshots, stable word IDs, paired grams,
atomic publication and retries, polyphonic readings, corpus review exports,
user compound discovery from word grams, removal of retired user character
files, and concurrent imports.

Scoring fixtures verify shared Chinese and English unigram totals, equal
unigram scores at equal counts, cross-language word histories and continuation
totals, lower-order fallback, and ranking with preceding text.

Segmentation regressions cover `没有输入法` → `没有 / 输入法` in base
paragraph ingestion, user ingestion and preceding-field ranking, bounded
user frequency influence, source-byte coverage and ASCII-run preservation.
Run `cargo test --locked -p si-engine --test segmentation` to check that the
one-bit cost applies to each additional segment and still allows stronger splits.
User ingestion tests also check that URLs with different paths or query
strings share a scheme-and-host word ID in grams with the surrounding words.
The full URL and its discarded pieces must be absent from the learned vocabulary.
After rebuilding the app, verify these boundaries with synthetic Sentence
Learning captures and preceding-field context in a representative host.
Existing saved statistics are retained; use a fresh synthetic profile when
checking newly counted grams.

Run `python3 -m unittest discover -s Tests/ScriptTests` for synthetic packaging
and installer checks. For vocabulary-only changes, use the
[standalone lexicon validation](CHINESE_VOCABULARY.md). Run
`python3 -m unittest discover -s Tests/VocabularyTests` for CSV and migration
fixtures.

For synthetic timings use `./scripts/benchmark.sh`. For quality/recall regression
reports use the [ranking dataset and candidate export](../eval/README.md).
Record the exact resource configuration with results.

`reused_search_statistics_preserve_edits_context_and_request_preferences`
compares reused and fresh engines across append/delete traces, languages,
context, preferences, personal phrases, aliases, separators, and casing.
`concurrent_queries_share_resources_without_sharing_compositions`
checks simultaneous independent spellings. The memo collision regression
checks exact-key validation after bounded replacement. Repeat the synthetic
host checks above after an explicitly requested build/install; cached engine
parity alone does not establish InputMethodKit compatibility.

### Known Rust recall misses

These authored examples are absent from the engine's whole-input results.
The table records the resources and search stages used to reproduce each miss.

| Input | Expected candidate | Confirmed with |
| --- | --- | --- |
| `zhaojichujuzi`, `zhao'ji'chu'ju'zi` | 找几处句子 | Bundled dictionary in Swift preview and full search. Local `.silex` + `.sigram` in CLI full search. Both were checked with Chinese only and with Chinese and English enabled. |

The bundled dictionary has `找` (`zhao`), `几处` (`ji'chu`) and `句子`
(`ju'zi`). The known issue remains tracked by
[`ChineseSentenceAlternativesTests`](../Tests/SICoreTests/ChineseSentenceAlternativesTests.swift).

### Pinyin correction evaluation

Run the CLI with the same lexicon and paired grams that will be evaluated.

```sh
cargo build --release --locked -p si-cli
python3 scripts/eval-pinyin-correction.py --grams Data/Engine/words.sigram
python3 scripts/eval-pinyin-correction.py --grams Data/Engine/words.sigram --offset 5000 --seed 361
python3 scripts/eval-pinyin-correction.py --grams Data/Engine/words.sigram --search preview
python3 scripts/eval-pinyin-correction.py --grams Data/Engine/words.sigram --vocabulary diming --show-errors
```

The script samples maintained public vocabulary and synthesizes a missing key,
neighboring-key substitution, or adjacent swap per selected spelling.
Its JSON report includes clean suggestion counts, typo
recall by edit type and Release CLI round-trip timings. It also distinguishes
misses with and without an ordinary complete Chinese result, excluding
targets already in the ordinary top four. It checks literal
fallback, full consumption, the suggestion cap and identical ordinary rows
with correction on and off. Use separate frequency bands and seeds for
calibration and evaluation. Use `--vocabulary` to sample a maintained
dictionary such as place names (`diming`) or notable people (`mingren`).
Use `--explicit-boundaries` to keep syllable apostrophes in both the clean
and mistyped spelling. Use `--cross-row-neighbors` to generate neighboring
substitutions across QWERTY rows. Use `--length-band long` for five- to
seven-character vocabulary, for example with `--vocabulary shici`. The clean ordinary-target count indicates how many expected words are
available in the loaded snapshot. Use `--show-errors` to include the generated
spelling and candidate outputs for missed targets and clean suggestions.
Use `--correction-mode higher-recall` with the same seed and vocabulary to
compare against the default conservative mode. The timings include CLI formatting
and IPC. The `on_minus_off` percentiles summarize paired round-trip differences
for the same spelling. The script alternates which setting runs first.
Use `--languages zh-Hans` with the same sample to isolate the effect of English
matches from Chinese search and ranking.
With paired grams, pass `--preceding` with synthetic text to compare both
correction settings under the same preceding context. The report records
whether context was supplied and omits the text.
With the bundled dictionary and paired grams, compare `sihuan` and `jihang`
in Higher recall with no preceding text and with `--preceding '他买了机票，准备去'`.
In the recorded synthetic check, the latter offered `四川` and `机场`
while retaining `四环` and `几行` as the first ordinary candidates.
The offline preview run measures the narrow search and includes timings
for all prefixes of a fixed set of typing sequences.
Pass `--stress` to measure clean and mistyped repetitions near the composition
length limit, separately from the vocabulary sample.
Host interactions and naturally occurring spelling errors require separate
evaluation.

For a whole-sentence smoke check with the production resources, compare
`womenjintianqugongyuan` with `womenjintainqugongyuan`,
`wozaixuexizhongwen` with `wozaixuexizhongwn`, and
`mingtianjian` with `mingtiamjian` in Higher recall. Check that the clean
spellings produce no suggestions and the edited spellings offer
`我们今天去公园`, `我在学习中文`, and `明天见` respectively.

## Manual input-method verification

Use an intentionally installed build. Follow the [local installation instructions](../README.md#install-for-local-development).
Run the cases in TextEdit, a browser field, a code editor, Terminal and an
office app. Include ordinary and secure fields, using dummy input.

- Check that SI is one selectable source under English and that closing Settings
  leaves the server available. Check upgrade from the legacy bundle identifier
  and preservation of preferences with a synthetic profile.
- Use `xcrun swift scripts/register-input-source.swift --check "$HOME/Library/Input Methods/SI.app"`
  to inspect registration. Test installation/upgrade with Developer ID Application
  signing, preserving enabled sources, saved settings and existing data. Check
  that an active process, unavailable identity or failed replacement cannot
  leave a broken installation. Check signed Installer and update behavior
  separately when preparing a release.
- Type `shi`, `he` and `nihao`. Verify applicable Chinese and English candidates
  coexist, and page to the literal. Disable one language, then both, and verify
  that the candidates follow the language settings and the exact literal stays.
- Type `xian` and `xi'an` to check the syllable boundary. Test ü/v/u: variants
  and exact prefix consumption, including a trailing syllable separator.
  Choose `你好` from `nihaopengyou` using Space, a digit and a click. The exact
  remainder must stay marked and editable, without an inserted space.
- Type `iwanttobuild`, `IWANTTOBUILD`, `woxiangyaodeploy` and `MySwiftType`.
  Inspect English word spacing, case and mixed output. Return and shortcuts
  must preserve the exact pending spelling. Escape clears the composition.
- After synthetic `中文`, confirm English `hello` using Space, a number and a
  mouse click; expect `中文 hello` without a trailing space in all three cases.
  After `hello`, confirm Chinese `中文`; expect `hello 中文`. Repeat after an
  existing space, full-width space, tab/newline, emoji, punctuation, digit and a
  supplementary Han character. Only adjacent Chinese/English boundaries should
  gain a separator. Check same-language boundaries and field starts remain
  unchanged. Repeat with the composition caret in the middle, mixed candidates,
  prefix remainders and explicit literal choices. Return/shortcuts must keep exact
  spelling, and punctuation candidates receive no decoration. Recheck focus
  changes, secure/direct input and hosts without surrounding-text support. With
  Input History independently enabled, only SI-inserted spaces belong to submitted
  output; existing host text is not recorded. Automated `CandidateSpacingTests`,
  `CandidateBoundaryReaderTests` and `InputHistorySettingsTests` cover policy,
  bounded UTF-16 reads, stale state rejection and submitted bytes; they do not
  establish native host compatibility.
- Type `youshihou` and verify dictionary completions such as `有时候是`
  appear only if ranked in the leading four choices. Check that at most nine
  exact word choices remain, while Chinese dictionary characters and exact
  original input stay pageable. Repeat with English completions and verify
  number/mouse selection in compact and expanded layouts.
- Type `shi` and press Down to expand while keeping the selected candidate.
  Use Down past the fifth row, then Up back to the first. The list should
  scroll one row as the highlight reaches an edge, preserving the column when
  possible. Use Page Up/Down to move several rows. Check numbers 1–6, Space and
  clicks on newly visible candidates, including a partial final row. Confirm
  that edits reset the highlighted row and scroll position. Check that prefix
  candidates have no arrow and retain their descriptions in tooltips and
  VoiceOver. Verify Home/End, backward/forward Delete and UTF-16 marked ranges
  with synthetic combining text.
- With Pinyin correction off and then on, type Chinese, English and mixed
  spelling, delete letters one by one, and insert in the middle. Every edit
  must return with current candidates, visible numbers and the first item
  highlighted. Space, digits, clicks, navigation and expansion should work
  immediately on that list. Confirm long-input response time with synthetic
  examples, especially with correction enabled. Deleting the last letter
  must close the panel. Start another composition and change languages or
  learning settings. Check that each confirmation inserts once and Return,
  shortcuts, cancellation and focus changes preserve their existing behavior.
- With paired word grams, compare the same ambiguous spelling after different
  synthetic preceding sentences. Change earlier sentences while keeping the
  last sentence fixed. Repeat in the middle of a field and over a selection,
  using emoji before the insertion point to exercise UTF-16 ranges. Confirm
  that the next search after a prefix commit uses the new field text. Switch
  fields or apps while work is pending and check that secure, direct-input and
  unsupported fields do not use the previous field's rankings.
- Try `nihao,world`, `nihao.test`, `user@example.com`, `foo/bar` and
  `My_Type+=Value` under the punctuation policies. Check literal spelling,
  no duplicate delimiter insertion, and no learning from delimiter commits.
- Check compact/expanded text, numbering, symbols, pagination, keyboard use,
  and VoiceOver. In light and dark appearances, check that the selected
  candidate uses a solid system accent (blue by default) with white text and
  numbering. Check the lighter active-row tint in the expanded layout and the
  selection outline with Increase Contrast. Inspect the panel near screen edges,
  with multiple displays and during marked-text wrapping.

### Local model ranking in a host

With fresh preferences, verify Local model ranking starts on in Typing Settings.
Turn it off, restart SI and verify that the choice persists. Compare
`xianzaitianjiazimu` in an empty TextEdit field with the option off and on.
With the bundled snapshots, the model can move `现在添加字幕` ahead of
`现在添加字母`; both should remain selectable. Repeat with Pinyin correction
enabled, then type `nihoa` with each option enabled independently. Check
keyboard and mouse selection, Return's exact spelling, focus changes, and a
second host such as Safari. Repeat in an eligible field with preceding text,
then verify direct and secure input suppress model use. Check VoiceOver's
setting label and value. The automated integration test covers the two
correction modes and the separation between model and statistical scores.
The Rust regression `small_reranker_scores_beyond_two_bits_and_caps_the_bonus_at_two`
uses `yuanshipinxie` to verify scoring across statistical gaps above two bits,
the two-bit bonus cap, and preservation of the original statistical score.
`small_reranker_scores_twelve_homophones_and_excludes_the_thirteenth` verifies
the 12-candidate pool limit and preservation of the exact original spelling.

### Pinyin correction in a host

With fresh preferences, verify Pinyin correction starts on in Typing Settings.
Turn it off, restart SI and verify that the choice persists, then turn it on again.
In TextEdit and a browser field, type `nihoa`. Check that `你好` is labeled
as a spelling correction and the original spelling remains selectable.
Accept with its displayed number, a click and arrow navigation followed by
Space. Confirm each inserts the candidate once. Navigate to the suggestion,
then type a comma or Tab and verify it does not accept the suggestion or
convert the delimiter. Check that the first displayed candidate is initially
highlighted, including when a statistical correction ranks first. Space
confirms the highlighted candidate. Return preserves the original spelling.
With the paired resources and a blank field, type `yehsi` and verify that
`也是` is highlighted in slot 1. Check that the leading corrections share
the four-choice shortlist rule with constructed results and completions.
Use VoiceOver to identify the suggestion in both candidate layouts. Change the setting
during composition and verify obsolete results cannot restore suggestions.
With the switch on, type `nihaoo` and `nihaox`.
Verify that the list contains the exact spelling and offers no whole spelling
correction to `你好` for either input. Repeat the `nihoa` case with the switch
off and check a secure field stays free of correction suggestions.

Verify that opening the expanded candidate list alone does not accept a
correction. Type `nihao` as a clean control with the switch off and on.
Exercise deletion in both modes and check that the first candidate is
highlighted for each edited composition.

## Candidate positioning

`CandidatePlacementTests` covers the start probes, anchor reuse during typing,
deletion and caret movement, anchor reset, invalid line rectangles, last-valid
and mouse fallbacks, below/above placement, resizing, visible-frame clamping,
and displays to the left and above the primary display.
`CandidatePanelOwnershipTests` covers a focus switch between rendering and display.

On an intentionally installed Debug build, type synthetic Pinyin such as
`dangqian` in a new Claude Desktop composer, the Chrome address bar, a Chrome
web input, Safari, Notes, TextEdit, VS Code, Terminal and a WeChat draft. Check
that the panel first appears beside the start of the composition. In Codex,
place the caret within a long line of synthetic text. Type until the marked
spelling wraps, delete back across the wrap, and move the caret with Home and
End. Confirm the panel stays anchored to the start of the spelling. In each
host, try rapid typing, a new line, the end of existing text, and starting
another composition after moving the window. Confirm a prefix and check that
the panel anchors at the start of the editable remainder. Repeat on a connected
external display. Check that expand/collapse and paging keep the resized panel
beside the composition and within the visible frame near the bottom and right
edges. Delete the entire spelling, press Escape, commit, switch focus and enable
a direct-input rule in separate compositions. A queued update must not restore
a dismissed panel or position it for another client. Exercise a shortcut during
composition to check that focus and host routing are preserved.

Enable geometry logging in the Debug build with the following preference. If
needed, restart the Debug input method to pick up the preference. Type in a
synthetic field to create the log, then follow it:

```sh
defaults write com.caterm.si debug.candidateGeometryLogging -bool true
tail -f "$HOME/Library/Logs/SI/CandidateGeometry.log"
```

Each placement uses one line in this order: UTC timestamp with milliseconds,
frontmost bundle ID, marked range, selected range, all attempted indices and raw
rectangles, selected index, display geometry, and final window frame. A selected
index of `none` indicates that the placement reused the retained anchor or
fell back when a host start rectangle was unavailable. Save the relevant
log lines and screenshots from synthetic fields per host. Logs exclude secure
input and typed content. The writer clears the file before an append that would
exceed 2 MB. Disable logging before deleting the file:

```sh
defaults write com.caterm.si debug.candidateGeometryLogging -bool false
rm -f "$HOME/Library/Logs/SI/CandidateGeometry.log"
```

Live host behavior requires login-session verification.

## Settings navigation

1. Open **SI Settings…** from the input menu. Confirm **Typing** opens first and shows the language switches and composition controls.
2. Use the sidebar with the mouse and keyboard. Confirm selection and the page heading agree, the detail pane scrolls independently, and switching pages starts at the heading. Search for “punctuation”, “export”, “screen recording” and “标点” in the corresponding interface languages. Check a search with no matches, clear it with Escape or the clear button, and verify the full sidebar returns.
3. Visit Personal Phrases, Personal Learning and Input History. Confirm each management sheet opens and closes, each consent switch is independent, and canceling clear confirmations and export panels leaves stored data intact. Use synthetic data. Check the two experimental permission statuses and the update availability in **About SI**.
4. Repeat in English and Simplified Chinese at the minimum window size, in light and dark appearances and with Increase Contrast. With VoiceOver, confirm the sidebar selection, page and group headings, control labels and switch values are announced. Check keyboard focus on returning from management sheets.

## Input-menu language switches

Run `./scripts/test.sh` and `./scripts/build.sh`. `LanguageSettingsTests` covers independent language persistence, configuration invalidation, unchanged direct-input rules and recording consent. `DeferredCandidateTests.languageChangesKeepCompositionAndCaretWhileRejectingOldCandidates` covers language changes through English-only, neither, Chinese-only and both, retaining exact input/caret, rejecting obsolete preview/final results and restoring ambiguous bilingual candidates.

On an intentionally installed build, select SI and open the macOS input-source menu. Check that English and Chinese (Simplified) reflect Settings, toggle independently, persist after a normal restart and have no keyboard shortcuts. With both enabled, `he` must retain English and Chinese choices; with neither enabled, exact original spelling must remain available. During composition, move the caret and toggle a language: preserve marked spelling/caret, refresh choices, and prevent an old candidate click or automatic-confirmation timer from committing a stale choice. Repeat in TextEdit, a browser field, an editor and Terminal, including focus changes and host shortcuts. In an app with direct input enabled, language checkmarks must not override passthrough; disable that app rule in Settings before testing conversion. Check menu keyboard navigation, VoiceOver checkmark announcements and English/Chinese UI labels in light/dark appearance. Automated tests/builds do not establish native menu routing or host compatibility; these checks require a login-session verification.

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
synchronous typing and deletion, unknown identifiers, disabled languages,
caret positioning near screen edges, light/dark appearance and VoiceOver. These
native host and spoken accessibility checks remain unverified by package tests.

## Language-labeled punctuation candidates

Run `./scripts/test.sh --filter 'PunctuationCandidateTests|CompositionBoundaryTests|CandidateViewTests|LanguageSettingsTests'`. Synthetic cases cover `, . / ; ' "`, default-off generation, persisted independent settings, synchronous candidate refresh on toggle, enabled-language filtering, unique identities, exact original spelling, complete-word punctuation, retained Pinyin separators, domains/code, bounded repeated punctuation/output, personal/verbatim archive exclusions, no vocabulary/context training, stale results and preview/full delivery. AppKit view checks verify visible E/C/A badges immediately after the candidate text, separate glyph/label frames, exact numbered commits and light/dark offscreen rendering in both layouts. Set `SI_PUNCTUATION_SNAPSHOT_PATH=/tmp/si-punctuation` to write those synthetic snapshots.

On an intentionally installed build, verify Settings → Typing → Show punctuation candidates starts off and remains off after restart. With it off, common punctuation outside composition must pass through immediately without a candidate window; trailing punctuation must not produce language variants or show language badges. Turn the switch on and restart to check persistence. While punctuation search/preview work is pending, switch off and verify stale results cannot restore variants, marked spelling/caret remain intact and old selections cannot commit a symbol replacement. Confirm the separate punctuation policy and language/learning choices are preserved.

With the switch on, use TextEdit, a browser field, an editor and Terminal. Start each `, . / ; ' " : ! ? ( ) [ ]` from an empty composition and check English/Chinese alternatives with small E/C badges plus A (As Typed), enabling each language alone and disabling both. In both layouts confirm using Space, numbers and mouse: insert the chosen mark exactly once, without a trailing space or language label, and retain host focus. Check Return preserves exact spelling, Escape cancels, and shortcuts/focus changes cannot commit a stale choice. With Keep Composing, try `nihao,` and `nihao.` followed by explicit candidate selection, then repeat while continuing `nihao.test`, `example.com`, `user@example.com` and `foo/bar` without selecting punctuation. Check `ni'hao` retains its separator and edits around punctuation refresh candidates. Repeat with the optional confirmation policies to retain their existing delimiter behavior. Check that each E/C/A letter is centered inside its badge in both layouts. Verify VoiceOver announces punctuation language/selection and labels remain legible in both appearances and Increased Contrast. Core and offscreen checks do not establish native event routing, host compatibility or spoken VoiceOver behavior.

## Direct input by application

Run `./scripts/test.sh` and `./scripts/build.sh`. `LanguageSettingsTests` checks initially disabled app rules, application scoping, restart persistence, unchanged language/consent settings and configuration invalidation. `ApplicationDiscoveryTests` uses temporary synthetic bundles to check grouped applications, duplicate identifiers, exclusion of nested helpers, explicitly selected apps outside the search roots, display names and rejection of missing identifiers. These automated checks do not exercise InputMethodKit event delivery.

Check that discovered and manually added apps show their system icons, missing apps show a generic icon, and icons stay aligned with names and switches while filtering and scrolling. Icons are decorative: VoiceOver should read the app switch's label once without a separate image announcement.

On an intentionally installed build, open **Direct Input → Manage Direct Input…**. Search for Terminal by name and bundle identifier, enable its switch, close/reopen Settings and restart SI normally to check persistence. Confirm standard-folder and running apps appear, Refresh picks up changes, Add Application accepts an app elsewhere, and an enabled missing app remains removable by its identifier. Check the search, switches, file picker and Done button using the keyboard and VoiceOver, in light/dark appearance and Increased Contrast.

In a selected Terminal app, type synthetic `echo SI_TEST_42`, use Space, digits, Tab completion, Return, arrows, Home/End, Delete, Escape and Control shortcuts. Every key must reach the host once, without candidates, automatic spacing or an extra Return to finish composition. Repeat with punctuation candidates and automatic confirmation enabled. Switch to TextEdit and verify ordinary Chinese/English candidates, selection and literal Return still work. A browser rule must apply to both its address bar and page inputs; an editor rule must apply to both editor and embedded terminal. No system input-source selection or Accessibility/Input Monitoring prompt should occur.

Toggle direct input across an active composition or pause timer, then return to the host, use candidate mouse/page/expansion controls if still visible and change focus rapidly. Only the exact pending source spelling may be inserted, once, with no extra space; obsolete candidates/timers must not convert or restore it. Turn direct input off and verify fresh conversion, without stale selection or history. With vocabulary/history independently opted in, confirm direct input adds no app records or incomplete history suffix, including after Return; existing records must remain deletable. Inspect data only with synthetic input. Native host, reentry, VoiceOver and appearance checks remain unverified until performed in a login session.

Verify the default **Control + Shift + I** in TextEdit, a browser, an editor and Terminal with SI selected: toggle on/off with an empty composition and with synthetic pending spelling. Confirm the rule affects only the IMK client app, persists across restart, and matches the Settings manager. Hold the shortcut: only one toggle occurs and no letter/control text reaches the host. Add Option or Command, or release Shift: the default must not match. Caps Lock must not prevent a match. Test focus changes, a pending candidate search and AI prediction; entering direct input inserts exact remaining spelling once, with no suffix or stale candidate/prediction. Secure fields and clients without an identifier must not change rules.

In **Direct Input**, record a custom modified printable key, confirm it replaces the default immediately and survives restart, then reset it. Escape and Cancel preserve the previous shortcut; unmodified/Shift-only keys and repeats cannot be recorded. Check Command combinations, keyboard focus/Tab traversal, VoiceOver labels and light/dark appearance. Verify Settings search finds the shortcut in English and Chinese. System/host-reserved shortcuts may take precedence. These native shortcut and recorder checks require a login session and remain unverified until performed.

## AI completion

Run `./scripts/test.sh --filter 'AICompletion.*Tests'` and `./scripts/build.sh`. Tests cover IMK text ranges, manual Tab routing, window selection, multimodal request encoding, local CLI fixtures including image cleanup, proxy/certificate environment preservation, static system proxy fallback and explicit-value precedence, HTTP limits, cancellation and second-row presentation. They use synthetic data and do not establish live model or host compatibility.

For CLI proxy verification, use a local test proxy and synthetic input. Check uppercase/lowercase proxy and bypass variables, explicit empty values and a custom CA path with both installed CLI backends. Launch SI normally from the GUI with static macOS HTTP/HTTPS or SOCKS proxy settings enabled and no inherited proxy variables, then verify requests reach the configured proxy. Explicit environment values must take priority. Do not include proxy credentials or input in diagnostic output. CLI PAC/WPAD and system proxy password retrieval are not implemented. Successful environment-builder tests do not establish the installed backend's network behavior.

On an intentionally installed build, enable AI Completion and grant Screen Recording using its explicit Settings action. Verify that the AI Context Access section and app allowlist are absent, and that the feature works in conversion-enabled TextEdit and browser fields without Accessibility permission. Type a synthetic composition and wait; no image capture or AI request should occur until plain Tab. Press Tab once, check progress, then press it again after the suggestion appears and verify one exact insertion. Busy and repeated Tab must not start extra requests. Test mouse acceptance, no suggestion, Shift/Command/Control/Option-Tab, AI disabled and Tab outside composition.

For each provider, verify that a synthetic fact visible elsewhere in the same window can inform the continuation. Test a second window of the same app and an editable floating panel, then focus and app switches, edits, candidate navigation, Escape, secure input and direct-input apps while capture or inference is pending. Old screenshots/results must not restore composition or commit to another field/window. Check a host whose reported IMK level differs from its visible window layer and verify same-app window fallback. Verify distinct messages for a missing input-app window, a window absent from ScreenCaptureKit, and a framework failure with its domain/code. Revoke Screen Recording and verify a specific error with no automatic permission prompt. Check temporary Codex image cleanup on success, failure and cancellation. Test English/Chinese Settings, keyboard use, VoiceOver and light/dark appearances. Verify independent Input History records only accepted text and Personal Learning stays unchanged.

Native screenshot smoke verification on November 8, 2026 used the production `AICompletionScreenshot` source in an isolated test executable and a temporary synthetic window. Screen Recording preflight succeeded; the selected Window Server ID matched the test window; ScreenCaptureKit returned a decodable 640×400 PNG with the expected red-dominant content, also visually inspected. This verifies single-window capture and encoding, not InputMethodKit key routing or live provider inference. A follow-up native smoke check deliberately supplied a nonmatching IMK level and verified same-app fallback still captured the intended synthetic window with the expected image content. Full two-Tab host, Settings and VoiceOver verification remains pending.

## Experimental permissions

Run `./scripts/test.sh` and `./scripts/build.sh`. Permission controls are separate from language, direct-input, learning and history settings. No focused-control detection or field-based automatic input behavior is implemented.

On an intentionally installed build, open **Permissions** and verify that both permission names, statuses and actions fit at the minimum Settings window width in English and Simplified Chinese, including when their statuses differ. Check keyboard navigation, distinct VoiceOver names for the two **Open Settings…** buttons, and light/dark appearance. With Accessibility disabled and System Settings closed, choose **Open Settings…** on the Screen Recording row and verify that the correct pane and floating panel appear without an Accessibility prompt. Drag SI from the panel into the list and confirm that macOS accepts the bundle from `~/Library/Input Methods/SI.app`. Revoke the grant in System Settings and repeat with System Settings already open. Open the Accessibility pane from its row and check that the panel closes when System Settings quits. Verify keyboard-only authorization using the system list's **+** file chooser and **Shift-Command-G**. Test the floating panel in English and Simplified Chinese.

Return to SI and refresh status after each change. If macOS requires a restart, restart the installed copy normally without running a second SI process. Neither launching SI nor typing should prompt. Granting either or both permissions must leave ordinary candidates, enabled languages, direct-input app rules and learning/history consent unchanged. With AI completion off, no host controls or images should be captured.

System permission dialogs, revocation, Settings keyboard/VoiceOver and live appearance remain unverified until exercised in the login session.

## App vocabulary

Use a dedicated synthetic profile on an intentionally installed copy. Settings calls this feature **Personal Learning**.

1. Confirm learning starts off. Enable **Enable Personal Learning**, select a nonfirst `shike` candidate in TextEdit, then type the identical spelling in TextEdit and a browser/editor: the remembered candidate must be the first ordinary choice. A deliberate different selection must replace it everywhere, including after restart. Explicit personal-phrase pins keep priority. Other enabled-language choices and exact original input remain available.
2. Accept the first choice using Space, number 1, mouse and navigation away/back: usage rises, but frequency strength, correction count and remembered choice do not. A later page's first cell still counts as nonfirst. Every third deliberate nonfirst selection earns one additional frequency point up to 32. Exact first-choice placement works after the first correction, separately from that bonus. Test immediate keyboard selection and selection after background delivery in both layouts.
3. Check exact normalized spelling (case and ü/v/u: aliases), explicit apostrophe boundaries, shorter input and a longer pending suffix. Only the exact remembered whole spelling gets forced placement. Select a prefix, then confirm its consumed spelling alone is remembered; its pending remainder must never be saved or pinned. Automatic, delimiter, punctuation, literal and personal/verbatim commits never train. Return and shortcuts retain their existing exact-spelling behavior without duplicate commits.
4. **Manage Learning Data…** searches global words/input, forgets entries and clears all learned vocabulary. Forgetting a selected entry restores ordinary ranking. Explicit phrases remain. There must be no application picker, app discovery or per-app pause/delete/clear controls. Seed the retired `applicationMemory.vocabularyExclusions` key and confirm startup removes it without changing the global learning switch or limiting suggestions. Check off/on consent, the separate direct-input feature, secure input and disabled languages. Changes during pending work must invalidate stale results/clicks. Restart preserves global consent.
5. Use synthetic archives only. Schemas 1–3 atomically become global schema 4 without app identifiers or history. Equal spelling/language/output rows merge bounded counts and maximum strength; schema-1/2 ambiguous strengths/corrections reset, while schema-3 evidence remains. Old last-use times must not create exact-choice markers. Old records still in the file survive age changes, and newer schema-4 selection markers persist across restart. Corrupt JSON/vocabulary/unsupported schemas must preserve original bytes; check migration-write and clear/retry errors and that older queued writes cannot undo deletion. The separate retired shared archive remains untouched.
6. Advance a synthetic clock by at least a year: global records, selection markers and frequency bonuses remain unchanged. Exceed 5,000 records and verify deterministic least-recently-used capacity eviction, including removal of selected/token effects for evicted rows. Forget and clear must still remove records across all apps. This is no age expiry, rather than unbounded storage.
7. Check English/Chinese interfaces, keyboard navigation, VoiceOver, empty/search results and light/dark appearances. Check that candidate-choice preferences update only on eligible SI confirmations. The old Sentence History archive has a separate deletion control under Personal Phrases.

`ApplicationVocabularyLearningTests` covers one-correction exact placement in final/provisional results, normalization/separators, consumed-prefix boundaries, replacement even with equal timestamps, neutral default acceptance, language/mixed identity, explicit pins, no decay/expiry, bounded rewards and exclusion/deletion. `ApplicationMemoryStoreTests` covers schema-1/2/3 merging, retired-field/app-identity removal, old-record retention, restart/permissions, malformed-file preservation and revision-ordered deletion. `ApplicationMemorySettingsTests` covers global snapshots/counts, independent consent, retired-exclusion cleanup, secure-input suppression, deletion, persistence and obsolete-result rejection. `CandidateLearningTests` retains number/mouse/navigation/page confirmation coverage. Core `LearningProfile` fixtures keep the optional historical decay/context API; those fixtures do not enable age expiry or previous-word learning in the app.

### Continuous manual prefix learning

With Personal Learning enabled, type synthetic `suocheng` and select `锁` then `成`, using Space, number and mouse selection in TextEdit and a browser. Confirm the remainder stays editable after `锁`, the host receives `锁成` once, individual learning entries remain, and a nonfirst correction makes `锁成` the first ordinary candidate on the next exact spelling. An all-first sequence must not gain correction priority. If Input History is independently enabled, confirm it contains the two actual submissions and no synthetic `suocheng` row.

Repeat with an edited remainder, Escape, shortcut/literal commit, automatic confirmation, personal/verbatim/punctuation choices, focus/client changes, consent off/on, learning deletion/clear and secure/direct input. No interrupted sequence may create the combined entry. Check exact apostrophes and ü/u: aliases, delayed candidates, and ordinary Return/Tab routing. These native host, reentry and keyboard/mouse checks remain manual; `CompositionLearningTests` covers the shared state and ranking behavior with synthetic fixtures.

## Input History

Use a dedicated synthetic profile and an intentionally installed build; never record private text or install a second SI instance as incidental verification.

1. Confirm **Input History → Save Input History** starts off independently of Personal Learning and all retired history flags. Enable it alone and submit `nihao` → `你好`, English candidates, Return-literal `Hello`, personal phrases and punctuation. Each successful SI submission must create one row with exact original spelling/output and time. Repeating the same submission must create a different record. English auto-space and SI punctuation replacements belong to output; keys passed through outside composition do not.
2. Confirm a Pinyin prefix with ü/u:/v aliases and explicit apostrophes: save only consumed original spelling, never normalize displayed history or include the pending remainder. Automatic prefix commits create separate rows, and the later remainder commit creates another. Cancel/edit without submission, Return outside composition, direct-input apps and another system input source must not record. Test Space, number, mouse, Return, delimiters, focus and shortcuts for unchanged insertion/commit behavior and no duplicates.
3. Check secure input before/after host calls and off/on consent changes during pending/reentrant work. Recording must be suppressed without reviving stale consent. Neither history consent nor viewing/searching history enables learning. Disable history, finish accepted writes, restart and inspect retained rows without recording new ones. No clipboard, document, URL or raw event data is queried.
4. View, search literal substrings (including SQL punctuation), page backward/forward and Refresh in English/Chinese UI, light/dark appearance, keyboard-only use and VoiceOver. Each page has at most 100 rows. New submissions and backward clock changes must not duplicate/skip older keyset pages. Test deletion while search/page requests are pending; late reads cannot restore deleted/cleared rows.
5. With synthetic data, exceed 5,000 rows and use timestamps many years old: history must retain all rows without age/count eviction. Delete one row, clear while writes are queued, and restart; nothing deleted may return through a stale insert or retry. Learning, explicit phrases and retired archives stay unchanged. Do not clear real archives as preparation.
6. Test corrupt JSON-like bytes, unsupported SQLite user_version, invalid schema, write errors and limited disk access using temporary synthetic stores. Original corrupt/unsupported bytes remain untouched. Errors pause recording, retain accepted failed records in memory for Retry Saving History and expose reopen/clear recovery. Retry the same event twice without duplicates. Clear removes the history database and sidecars; backups/forensic remnants are outside these controls. Normal termination drains accepted queued writes; forced termination and unretried errors can lose unsaved entries.

`InputHistoryStoreTests` covers 5,005 old/repeated records, exact Unicode/NUL bytes, retry identity, sequence pagination under newer/backdated inserts, parameterized substring search, permissions, independent deletion/clear, invalid batches and corrupt/unsupported preservation. `InputHistorySettingsTests` covers independent consent, old-flag isolation, consumed-prefix/source/output boundaries, secure-input suppression, consent-generation rejection, queued-clear ordering, deletion and failed-write retry. These synthetic checks do not exercise native host reentry, secure fields, Settings keyboard/VoiceOver or actual appearance; those remain manual.

### Sentence learning

`ReturnFieldLearningTests` covers the fixed 2,048-unit request, a native text
view clamping the range on both sides of the caret, and the former Sentence
History path when the client only answers a request ending at the caret.

- Use an isolated synthetic profile with Personal Learning and Input History off. Enter a sentence via separate Space, number or mouse selections, edit a word in the host, and use a Return or Command–Return that clears or leaves the field. Verify the edited sentence feeds cross-word grams once, the edited-out word is absent and the derived model survives restart.
- With an active composition, press Return and verify it inserts only the exact remaining spelling, once. Check the spelling is eligible for Sentence Learning on a subsequent Return that is passed to the host and ends the field. Verify that individual candidate confirmations, shortcuts other than Command–Return, Escape and switching fields without a pending Return leave the model untouched.
- Check end-of-field newline and unchanged text skip ingestion. Inserting a newline in the middle triggers ingestion when it breaks literal containment. Try TextEdit, a browser address bar and a chat composer. Include rapid typing after Return, paste, secure/direct input and clearing learning before readback. Check Settings focus, VoiceOver and both localizations.
- Verify the Sentence Learning page and sample display are gone in both languages. Upgrade an isolated profile with a synthetic recent-samples sidecar. Verify the file is removed and its paired vocabulary and grams survive. Check Delete All cancels pending learning even during a write, and legacy SQLite deletion is still available under Personal Phrases.

### Input History export and receiver tools

The Python suite below also checks `scripts/input_history_to_txt.py` with
synthetic Input History and legacy Sentence History exports: output-only extraction,
original order/repeats, exact Unicode/whitespace/control bytes, empty archives,
0600 permissions, explicit overwrite, and preservation of existing TXT files
when checksums, counts, versions or JSONL termination are invalid. This offline
script does not require an app build or native host checks.

Use synthetic archives and explicit temporary destinations. Verify **Export Input History…** in both the Settings section and history manager. The action must open the save panel directly, disclose private source/output/time and offer no backup/training choice. Cancel the save panel without creating a file or changing recording consent. Choose a JSONL destination and replace an existing export intentionally; failures must preserve it. Test keyboard-only operation, English/Chinese, VoiceOver and both appearances. No network/share action occurs.

Export with a search hiding all rows and on a later page: the file must contain every saved row in sequence order. Pending writes must finish first, unresolved save errors must block export, and normal termination must drain an accepted export. Use exact Unicode/NUL/casing/ü/separator/space fixtures, repeats and more than 5,000 rows. Check permissions, manifest version and absence of purpose flags, summary count/checksum, corruption/truncation/version/duplicate rejection and the Swift-export → Python-restore → native-read round trip. Native history remains unchanged.

Run `python3 -m unittest discover -s Tests/InputHistoryToolsTests -v` in addition to the shared suite. The receiver commands in [INPUT_HISTORY_EXPORT.md](INPUT_HISTORY_EXPORT.md) must refuse existing output paths, restore the ordinary export exactly and accept that same file for candidate preparation. Preparation produces only unsplit/unreviewed candidate CSV plus hashes/filter provenance. Automatic confirmations and literal tasks are excluded by default; an explicit flag admits ASCII literal/copy observations. Do not collect real data, print private text, alter maintained CSVs or start a training run as validation.

## Automatic prefix confirmation

Run `./scripts/test.sh --filter AutomaticConfirmation` and `./scripts/benchmark.sh --automatic-confirmation`. The benchmark emits paired Release full-search timings with/without evidence, caller-side edit/delivery timings excluding decoding, invariant checks for candidate order/scores/bytes, and fixed synthetic typing traces. It evaluates one-result-per-character, coalesced three-character deliveries and final-only delivery in Chinese-only and bilingual settings. Existing ranking fixtures, including the already inspected historical holdout, are development/regression evidence rather than an independent accuracy estimate. A correct committed prefix with an empty output counts as abstention, not successful conversion; inspect activation and false confirmations separately. Timings are in-process and do not establish native event latency.

On an intentionally installed build, verify the following in TextEdit, a browser text field, a code editor and Terminal. Installation is not incidental setup for this check.

- The Typing toggle is initially off, keyboard/VoiceOver accessible, and survives restart. Ordinary manual Space/number/mouse selection, Return, Escape, focus and shortcuts keep their existing behavior while off.
- Enable the option and gradually type `nihaopengyouxuexizhongwen`. Leading stable words should commit without a space while the ending remains marked, editable and represented by current candidates. Repeat with rapid typing; no dropped/duplicated letters or synchronous full search should be introduced on append or timer delivery.
- Type `nihaopengyou` and wait: `你好` may confirm after at least 1.8 seconds, leaving `pengyou`. Continuing to wait must not drain the rest. Type more to permit another confirmation. `shi`, `he`, `nihao`, short `dishiye`, English and mixed leaders, uppercase identifiers, unknown text and symbol-bearing input must not be forced into a prefix conversion. A pause must not confirm an isolated single-character prefix. Nearby homophones that disagree on the beginning must remain editable regardless of pause length. Repeat `nihaotitle` and `nihaotitlezhongwen` with English disabled; their English spans must still suppress automatic conversion.
- Before a pause fires, delete, move the caret, navigate/page candidates, expand/collapse the panel, press Escape, Return, a shortcut, or change focus. The old task must not insert text or restore candidates. Start a new composition, including the same spelling, and switch between clients; old work must remain invalid. End-of-buffer typing after an edit builds fresh evidence, while middle-of-composition edits remain manual.
- Change languages, punctuation, automatic confirmation, personal phrases, learning consent/clear and secure input during composition or while a pause timer is pending. Also toggle a typing setting away and back without another keystroke. Results and timers from the prior configuration must not commit. No language selection or enabled language alone enables learning.
- With a dedicated synthetic learning profile, verify automatic commits neither change saved record count/strength/timestamps nor supply previous-word context. Deliberate selections must still train under the existing opt-in rules.
- After automatic confirmation, Return/shortcuts preserve the remaining original spelling. Confirm Space/number/mouse prefix selection and candidate paging still agree with the displayed rows. Edit already committed text using the host's ordinary controls; automatic restoration of its original Pinyin is not implemented. Check marked UTF-16 selection, candidate positioning, both appearances and VoiceOver after a prefix is inserted.

Core regression tests and a successful build do not establish these native host checks. Record actual host/version, input, committed prefix, editable remainder, timing and any unexpected confirmation using synthetic text only.

## Personal phrase checks

Use an isolated synthetic `.si-user` profile. Verify Personal Phrases lists the same text, readings and counts as its active `user.silex`, including entries generated by Sentence Learning and entries without readings. Search, add, edit frequency, edit text/reading, and delete. Restart and verify persistence. Check duplicate/invalid/stale edits show errors without changing unrelated rows. Frequency edits preserve word grams; identity edits/deletions remove only associated grams and preserve unrelated counts/aliases.

Check edited vocabulary in conversion, language filtering and secure/direct-input suppression. Verify **Delete All…** clears entries and word grams after confirmation, while cancel preserves them. Check keyboard focus, VoiceOver and both appearances. Verify unrelated Personal Learning and Input History data separately. Automated storage and bridge tests do not establish native behavior.

## Candidate font coverage

Run `./scripts/test.sh --filter 'CandidateTextSupportTests|CandidateSelectionTests|CandidateViewTests'`. Coverage checks system fallback for ordinary/extension Han, combining marks and emoji, rejects a guaranteed-missing noncharacter alone or inside a word, preserves exact literal bytes and language identities, and verifies that missing candidates do not consume shortlist slots. The synthetic `heihe` regression checks provisional/full results, compact/expanded numbering, mouse identities and exact prefix commits against the filtered list. Engine results and public dictionary entries remain unchanged.

On an intentionally installed build, type `heihe` in TextEdit and a browser field, expand and scroll through candidates with Down and Up, and confirm that missing-glyph boxes are absent while supported rare characters remain selectable. Check Space, numbers, mouse selection, prefix remainders, Return, cancellation and focus changes in light/dark appearances and with VoiceOver. Coverage depends on installed system fallback fonts; no extension block is excluded wholesale. Original literal input remains available even if it contains an unsupported character. Automated Core Text and offscreen view checks do not establish live host or VoiceOver behavior.

## Software update verification

Script fixtures cover appcast build/display versions, the app-only archive URL/signature/size, invalid signatures, key mismatch, nested helper signing order, public-artifact failure isolation, newer/conflicting/malformed feeds, concurrent feed advances, ETag promotion and identical retries. They never use a real signing key or contact Apple/R2. Run `python3 -m unittest discover -s Tests/ScriptTests -v`, both app build configurations, and a release dry run with explicit synthetic certificate names. Inspect the built `Contents/Info.plist` for the correct SI feed/key and disabled automatic checks/downloads/profile submission; confirm Sparkle.framework and its helpers are embedded, its notice is bundled, and staged nested signing passes `codesign --verify --deep --strict`. An unsigned build cannot establish signed update installation behavior.

In a disposable login session with an intentionally installed, signed Release build and two published synthetic test releases, check Settings and the SI input-menu action with keyboard/VoiceOver, light/dark appearance and long version text. Debug/uninstalled copies must explain why checking is disabled. Closing Settings must leave typing working. Launch/typing must generate no update request until Check for Updates is chosen. Confirm no-update, malformed/unreachable feed and bad-signature errors, cancellation, repeat checks, and the available-update flow. Inspect requests using only synthetic input; they must contain no composition, phrase, learning or host-document data. Exercise Universal and CPU-specific feeds, comparing the integer build counter with the displayed marketing version.

Finish composition/save work before choosing Install. Check pending learning/phrase writes survive normal termination, a single SI process restarts, enabled input sources/settings/phrases remain, and the installed path stays `~/Library/Input Methods/SI.app`. Confirm input in TextEdit, a browser, Terminal and an editor, then focus changes/shortcuts. Record whether log out/back in was needed for registration or resumed typing; do not force it. Cancelled updates must preserve the existing installed bundle. This app-bundle path does not use the pkg's Log Out screen. Keep the previous DMG for recovery and verify reinstall through the ordinary guarded installer in the disposable session. Do not install, publish, stop the user's running SI or log out as incidental automated validation.

## Website verification

For the independent static landing page, use the build, browser, localization, accessibility, and deployment checks in [WEBSITE.md](WEBSITE.md). These checks do not install or exercise the input method.

## Offline corpus and ranking checks

Use the [corpus guide](../corpus/README.md) for the pinned Python environment.
Run `corpus/.venv/bin/python -m unittest discover -s corpus/tests` for
synthetic archive parsing, normalization, document/source ranges and atomic
publication. Chinese Chatbot Corpus fixtures exercise all eight layouts,
source splits, attribution and rejection of mismatched Weibo pairs. With the
local files present, run `corpus/.venv/bin/python corpus/prepare_raw_text.py
--source chinese-chatbot-corpus` to prepare or verify the bundle. Use the
separate model guides for training or scoring tests.

Run `python3 scripts/evaluate_conversion.py check` to verify the separate
[decoder recall and fixed-pool ranking datasets](../eval/README.md).
Run the recall and ranking commands there to export complete decoder pools
and measure the character scorer with paired context, ablated context and
context-free examples.

Run `python3 scripts/generate_ranking_eval.py --check` and
`python3 -m unittest discover -s Tests/RankingEvalTests` for the authored
historical 220-query suite. Follow the [compact suite protocol](../eval/README.md#validate-and-evaluate) to generate
blind requests and score the first 32 eligible complete candidates.
