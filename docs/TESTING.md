# Testing SI

## Automated checks

```sh
./scripts/test.sh
./scripts/build.sh
```

The package uses Swift Testing for ambiguity, language filtering, exact-match ranking, deduplication, literal preservation, Pinyin normalization, composition edits, stale selections, and consecutive commits from different languages. These tests do not launch InputMethodKit or register an input source.

The app build validates the SwiftUI, AppKit, and InputMethodKit integration against the active SDK. GitHub Actions runs both checks on macOS. A local build does not validate the hosted workflow itself.

## Manual input-method verification

Install with `./scripts/install.sh`, log out and back in if needed, add SI in Keyboard settings, and select it. Do not run a second copy from Xcode while using the installed input source.

- Open SI Settings from the input menu. Both languages should initially be enabled.
- Type `shi`. Verify Chinese candidates, English completions, and original input coexist. Scroll to the original input if needed.
- Type `he`. Verify the English exact match and the Chinese alternatives are both available.
- Commit `nihao` as `你好`, then `world` as `world`, without changing any language setting.
- Disable Chinese. Verify Chinese candidates disappear while English and literal candidates remain.
- Disable English as well. Verify text remains available as typed. Re-enable both languages.
- Use Space, Return, number keys, arrow navigation, scrolling, Delete, and Escape. Check the behavior against README.md.
- Enter an identifier such as `MySwiftType` and commit with Return. Verify case is preserved.
- Enter punctuation, a URL, numbers, and Tab; verify literal text and application shortcuts survive composition boundaries.
- Start composition and click elsewhere or change focus. Verify the original text commits once and the old candidate window closes.
- Close and reopen Settings. Verify language preferences survive a process restart and closing the window does not terminate the input method.
- Exercise two applications in succession to check that composition state does not leak between clients.
- Check candidate positioning near screen edges, on multiple displays, in dark mode, and using VoiceOver.

Run relevant cases in TextEdit (plain text), Safari or Chrome text fields, a code editor, Terminal, and office apps. Check secure text fields using dummy data only; macOS may choose a different input source for those fields.

Record the macOS version, host application/version, enabled languages, synthetic input, expected behavior, and actual output. System registration, key routing, actor-boundary assumptions, and host-app compatibility require this manual verification before release.

## Website verification

For the independent static landing page, use the build, browser, localization, accessibility, and deployment checks in [WEBSITE.md](WEBSITE.md). These checks do not install or exercise the input method.
