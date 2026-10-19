# Testing SI

## Automated checks

```sh
./scripts/vocabulary.sh build --check
./scripts/vocabulary.sh --language chinese build --check
python3 -m unittest discover -s Tests/VocabularyTests -v
./scripts/test.sh
./scripts/build.sh
./scripts/benchmark.sh
./scripts/benchmark.sh --resources > .build/candidate-benchmark.json 2> .build/resource-usage.log
```

The vocabulary checks run offline and verify deterministic generation, source precedence, durable exclusions/corrections, checksums, rejected imports, and failure preservation. Network refresh/audit checks are separate maintainer actions; their workflow does not install SI. See [English vocabulary maintenance](ENGLISH_VOCABULARY.md) and [Chinese vocabulary maintenance](CHINESE_VOCABULARY.md).

The package uses Swift Testing for ambiguity, language filtering, deterministic ranking, deduplication, literal preservation, syllable boundaries, initials, partial input, phrase construction, continuous mixed input, composition edits, and stale selections. Additional targets cover learning feedback, decay, expiry, bounded storage, restart, file permissions, malformed data, write failures, deletion ordering, opt-in/pause, secure-event suppression, and settings persistence. These tests do not launch InputMethodKit or register an input source.

The `SIPresentationTests` target checks the production selection model and AppKit views: visible digits/highlight, real `NSEvent` key values, last-page bounds, candidate identity, mouse button actions, literal reachability, and prefix/whole commits. It never shows a candidate window or operates another application. For a focused run with the related composition regressions:

```sh
./scripts/test.sh --filter 'CandidateSelectionTests|CandidateViewTests|CandidatePlacementTests|PartialCommitTests|CompositionEditingTests|CompositionBoundaryTests'
```

Set `SI_CANDIDATE_SNAPSHOT_PATH` to an output PNG path to retain the synthetic offscreen view render, with sibling `.dark.png` and `.compact.png` previews for dark and single-page layouts. This checks view drawing and state, not host key routing, live VoiceOver behavior, automatic system-appearance changes, or candidate positioning.

`CandidatePlacementTests` checks synthetic host geometry separately: composition-start queries, caret fallback, composition-local cached coordinates, invalid/missing coordinates, edge clamping, left/above displays, and display removal. It does not exercise InputMethodKit's actual coordinate delivery.

`MixedWordBoundaryTests` checks intact English versus a split Chinese ending with learning off and injected single-word preferences, including strong/combined preferences, casing, other English words, later continuation, exact literals, deterministic order, explicit apostrophes, and whole/prefix preferences. Run it with `./scripts/test.sh --filter MixedWordBoundaryTests`; fixtures do not read saved user data.

`benchmark.sh` emits Release-mode JSON for thirteen synthetic scenarios with a full 5,000-entry learning profile and 1,000 personal phrases. Cases include all matching personal prefixes, dense 64-letter input, unknown tails, repeated expansions of approximately 1,000-byte phrases, relevant learned tokens, and long Unicode/emoji phrases. `--resources` builds the executable, then uses macOS `time -l` to report process resource usage separately on stderr. JSON records maximum phrase size and a stable, noncryptographic fingerprint of synthetic candidate identity/order, scores, completion/prefix flags, and personal/verbatim flags. Fingerprints are computed outside timed regions; compare them as regression evidence, not as proof over all inputs. Retain machine/OS and iteration details when comparing results. These are in-process engine timings and CLI-process memory, excluding InputMethodKit, UI, IPC, storage, and host-app latency; they do not prove production vocabulary performance.

The app build validates the SwiftUI, AppKit, and InputMethodKit integration against the active SDK. GitHub Actions runs both checks on macOS. A local build does not validate the hosted workflow itself.

## Manual input-method verification

Install with `./scripts/install.sh`, log out and back in if needed, add SI in Keyboard settings, and select it. Do not run a second copy from Xcode while using the installed input source.

- Stop any Xcode run before installing. The installer should report both `Installed:` and `Verified: one selectable SI keyboard input source (com.caterm.inputmethod.si)`. A copied/signed app alone is not registration evidence. Registration must leave the current and enabled input sources unchanged.
- Run `xcrun swift scripts/register-input-source.swift --check "$HOME/Library/Input Methods/SI.app"` to query only SI's registration without enabling or selecting it. Close and reopen System Settings before falling back to logout if its input-source picker is stale.
- Find SI under **English** in the input-source picker. The registration check must report English as the primary discovery language. With both languages enabled, verify `he` and `nihao` still offer Chinese and English matches as applicable; the system category must not filter SI's enabled providers. Existing SI sources keep the same identifier when this discovery category changes.
- For an upgrade from `com.caterm.si`, verify the prior app is backed up, language/punctuation/learning-consent choices are preserved, and saved phrases/learning remain available. Check both initially disabled and explicitly enabled learning consent. A stale manually added source needs removal/re-adding by the user.
- Verify Xcode's `--settings` launch and the installed input menu can show Settings after the background declaration; closing Settings must keep the input-method server alive.

- Open SI Settings from the input menu. Both languages should initially be enabled.
- Type `subtitle`, `SUBTITLE`, `subtit`, and `nihaosubtitle`. Verify exact/completed English candidates, preserved capitalization, mixed output and the exact literal candidate. Try a broad prefix such as `a` and confirm native paging can reach the original text. Check Return, punctuation and application shortcuts with the expanded vocabulary.
- Type `zimu`, `shujuku`, `rengongzhineng`, and `zimusubtitle`; verify imported Chinese words, mixed output, exact spelling, disabled-language filtering and numbered paging. Compare `xing` and `hang` for `行`, and `lü`, `lv`, `lu:` in core tests. With synthetic `le` → `了` learning, `nihaotitle` must still prefer `你好title` over both English and Chinese-abbreviation splits. Check the broad prefixes `a`, `y`, and `sh` for paging and responsiveness.
- Type `shi`. Verify Chinese candidates, English completions, and original input coexist. Scroll to the original input if needed.
- Type `he`. Verify the English exact match and the Chinese alternatives are both available.
- Commit `nihao` as `你好`, then `world` as `world`, without changing any language setting.
- Enter `nihaoworld`, `hellozhongwen`, and `woaiSwiftshurufa`; verify mixed candidates, preserved English casing, literal fallback, and Space behavior at the end of each language.
- Compare `xian` with `xi'an`; only the latter must exclude the single-syllable `先`. Check a trailing apostrophe does not complete across a syllable boundary. Check `niha` for incomplete spelling, `srf` for stored-phrase initials, and `nhao`/`ni'h` for mixed full/initial spelling.
- Enter `nihaowor`; inspect both known-word completion and Chinese + As Typed alternatives. Use a synthetic unknown span with uppercase letters and verify verbatim characters/case survive. No candidate containing a verbatim span may train learning or become previous-word context.
- Enter `nihaopengyou`, navigate to the prefix `你好`, and confirm with Space and separately native/number selection. Only its source prefix should commit; the rest must remain marked, editable, and offer `朋友`, without an extra space. Return must insert the exact remainder; Escape must discard it. Test source offsets with apostrophes and unit fixtures for ü/u: normalization.
- Disable Chinese. Verify Chinese candidates disappear while English and literal candidates remain.
- Disable English as well. Verify text remains available as typed. Re-enable both languages.
- Use Space, Return, number keys, arrow navigation, scrolling, Delete, and Escape. Check the behavior against README.md.
- Enter `shi` and verify Down moves the highlight, Up reverses it, and Space commits the highlighted candidate exactly once. Press 2 in a fresh composition and verify the second visible row commits without inserting the digit. Page down or scroll, then press a number and verify it selects that visible row rather than a row from the beginning of the list. Check an absent row number on a short final page does not commit another choice. Outside composition, digits/arrows/page keys must reach the host normally; command/control/option shortcuts must keep literal passthrough.
- In the system input-source picker and input menu, verify the SI icon is centered beside its label on standard/Retina displays and in light/dark appearances. Check the charcoal rounded badge and white lettering remain visible, and the alternate light badge is legible in highlighted menu rows. Both TIFF assets must contain 16×16 and 32×32 pixel representations, each with a 16×16 point logical size. Regenerate with `xcrun swift scripts/generate-icons.swift` after generator changes.
- Type `niho`, move Left, and insert `a`; check that the marked composition becomes `nihao`, with the caret before its final `o`, and `你好` is offered. Exercise Home/End and Forward Delete without moving the host-document caret. Up/Down and page keys must still navigate candidates.
- Enter an identifier such as `MySwiftType` and commit with Return. Verify case is preserved.
- Exercise all three punctuation policies. In Smart Chinese Punctuation, `nihao,` should confirm `你好，`; Confirm Candidate should insert `你好,`; Keep Typed Text should retain `nihao,`. Check no punctuation is dropped or doubled. After a word has already committed, punctuation must pass unchanged.
- Verify unselected English words/completions remain literal on punctuation/Tab; actively choosing an English candidate permits confirmation. Incomplete personal codes must stay literal until explicitly chosen. Prefix candidates must not be confirmed by punctuation. Check mixed candidates ending in each language.
- Enter a URL, identifier, code separators, numbers, and Tab; verify literal spelling and application shortcuts survive boundaries. Delimiter commits must not train or retain previous-word context.
- Start composition and click elsewhere or change focus. Verify the original text commits once and the old candidate window closes.
- Close and reopen Settings. Verify language preferences survive a process restart and closing the window does not terminate the input method.
- Exercise two applications in succession to check that composition state does not leak between clients.
- Check candidate positioning near screen edges, on multiple displays, in dark mode, and using VoiceOver.
- In a browser address field and a plain text field, enter a long synthetic composition such as `nixiangyaoworld`. Verify the panel tracks its beginning rather than jumping to the screen center as input grows. Check Left/Right editing, prefix confirmation, cancellation, and focus changes; a new composition must not reuse another composition's position. Test standard/Retina displays, including a display arranged to the left or above the primary display and insufficient space below the input.
- Check that normal rows show numbers and candidate text without language descriptions. Prefix/original/personal hints must remain distinguishable; tooltips and VoiceOver should still identify candidate language and source. Single-page results must hide the footer; multiple pages must expose accessible previous/next chevrons and preserve number-to-row mapping. Check long mixed candidates and both system appearances.

Run relevant cases in TextEdit (plain text), Safari or Chrome text fields, a code editor, Terminal, and office apps. Check secure text fields using dummy data only; macOS may choose a different input source for those fields.

Record the macOS version, host application/version, enabled languages, synthetic input, expected behavior, and actual output. System registration, key routing, actor-boundary assumptions, and host-app compatibility require this manual verification before release.

## Personal learning checks

Use a dedicated test account/profile and synthetic data. Do not clear a person's existing preferences as an incidental test step.

- Confirm personal learning initially defaults to off. Candidate preview must not create records.
- Enable learning. Explicitly select `时` for `shi` several times; verify its position improves while English candidates and original input remain available.
- Train `woshi` → `我时`, then inspect the **First 5 characters** choices in `woshinihao`; the matching prefix should use the saved `woshi` preference, while complete candidates still come first. Forget the exact saved preference and confirm its effect disappears. When testing previous-word pairs, keep the separate option enabled and verify context-only preferences affect full/prefix choices without becoming token frequency records. Use automated synthetic lexicons for low-scored direct-entry versus composed-derivation cases.
- Enter `woshi` after repeated `shi` → `时` selections; verify the token preference raises `我时` without requiring that full spelling to be trained. Check ordinary alternatives, other languages, and literal input remain selectable. Restart, pause, secure input, forget, clear, and expiry must affect this token ranking too. Confirming a sentence must not automatically create records for its inferred component words.
- With a dedicated synthetic profile, learn `le` → `了`, then enter `nihaotitle`, `nihaotable`, and `nihaomaple`. Intact English words must precede their split `…了` alternatives. Confirm alternatives and exact literal input remain reachable. Check `nihaotitlele` and `nihaotit'le` retain ordinary token learning; explicitly learning the entire alternative `nihaotitle` → `你好tit了` may still promote that deliberate choice. Do not clear existing personal data to prepare this check.
- Compare actively choosing a candidate to accepting the first candidate with Space; explicit feedback should have greater influence.
- Turn learning off. Check that ranking returns to the base order and new input does not change the saved count. Turn it back on; saved preferences should apply again.
- Restart SI normally and verify both opt-in state and saved preferences survive. Do not run built and installed copies concurrently.
- Search saved preferences, forget one, restart, and verify it stays removed.
- Clear learning data after confirmation, restart, and verify it remains empty while language settings remain unchanged.
- Confirm Return, Escape, focus changes, shortcuts, punctuation passthrough, and dummy secure input do not create records.
- Check accessibility names, keyboard focus, confirmation cancellation, save progress, error feedback, and narrow-window scrolling in Settings. Candidate preview pages must provide access to every result, including the literal fallback.
- Enable the separate previous-word option. Choose `file` for `fi` after `open` and `find` after `search`; repeat and verify the corresponding context changes their order without removing candidates.
- Verify context disappears after cancellation, Return, punctuation/shortcuts, host navigation, focus/deactivation, changing languages, five minutes of inactivity, toggling consent, and clearing data. Switch clients to check that another field does not inherit the previous word.
- Search saved preferences by a preceding word; verify contextual records show “After …” and can be forgotten independently. Turning context off must stop using pairs while leaving them manageable.

Corruption, unsupported schema, retention, unwritable paths, and delayed-write ordering have isolated automated fixtures; do not reproduce them by damaging a real user profile. UI feedback and real event delivery still require manual checks.

## Personal phrase checks

Use synthetic phrases in a test profile. Add `xm` → `测试项目`, choose its language, and verify full-code and prefix suggestions with learning off. Prefer a full-code phrase and verify other languages and literal input remain available. Disable its language and check it disappears.

Enter `woaixm` and verify the saved phrase participates in a longer composition. Confirm it with learning enabled; neither the derived candidate nor its phrase text should appear in learning records or previous-word context. Use isolated fixtures for many colliding codes and long expansions; direct matches/literal fallback must remain available and constructed text must never be silently truncated.

Edit its code/text, delete it, and clear the dictionary; each change must survive restart and must refresh an in-progress composition on the next event. Cancel clear/editor dialogs and verify no unintended changes. Personal phrases must not appear in automatic learning records or become previous-word context.

Export a test JSON file, inspect its fields, then import it with duplicates and different local pin settings. Existing local content wins. Invalid/unsupported/oversized/capacity-exceeding imports must preserve all existing phrases. Cancelling import/export must not show a failure. Check search, keyboard focus, VoiceOver row/button labels, error persistence, retry, and long phrase layout. Native file dialogs and real secure-field suppression still require manual inspection; automated tests cover codec/model/storage behavior only.

## Website verification

For the independent static landing page, use the build, browser, localization, accessibility, and deployment checks in [WEBSITE.md](WEBSITE.md). These checks do not install or exercise the input method.
