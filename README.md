# SI

**One input. Every language.**

SI is an open-source macOS input method built around one idea: choose the languages you use in Settings, then type without switching between language modes. Candidates from enabled languages appear together, including ambiguous matches. The original text always remains available.

> **Status: development preview.** SI includes InputMethodKit integration, a bounded Pinyin word-lattice decoder, continuous Chinese/English composition, editable personal phrases, and optional frequency/short-context learning. English uses a maintained multi-source vocabulary; Chinese coverage remains limited; production-level vocabulary coverage, sentence-level ranking, and broad host-app compatibility remain work in progress.

## How it works

Enable **English** and **Chinese (Simplified)** once. SI queries both providers for each composition:

| Input | Example candidates |
| --- | --- |
| `shi` | `是`, `时`, `事`, `十`, `ship`, `shirt`, `shi` (as typed) |
| `he` | `he`, `和`, `喝`, `河`, `hello`, `help`, `her`, `he` (as typed) |
| `nihao` | `你好`, `nihao` (as typed) |
| `nihaoworld` | `你好world`, `nihaoworld` (as typed) |
| `woaiSwiftshurufa` | `我爱Swift输入法`, `woaiSwiftshurufa` (as typed) |

SI combines known words and syllables, including phrases not explicitly stored in the vocabulary. Apostrophes constrain syllable boundaries (`xi'an` distinguishes `西安` from `先`); stored phrases support initials (`srf` → `输入法`), mixed full/initial spellings (`nhao` → `你好`), and incomplete final spelling (`niha` → `你好`). Mixed decoding includes incomplete endings such as `nihaowor` → `你好world`. When no exact complete path exists, unrecognized spans can remain as typed, including their case. Such candidates are labelled **Chinese + As Typed** and are excluded from learning.

Whole-composition candidates come first. Candidates labelled **First N characters** confirm only a prefix and leave the rest marked and editable; for example, select `你好` from `nihaopengyou`, then continue choosing `朋友`. Prefix choices are ordered by how much input they cover. Return always commits the exact remaining spelling. This is bounded lexical search rather than a production statistical language model.

All processing is local. SI has no network client, analytics, keystroke logging, or cloud dependency. Language and learning settings are saved in UserDefaults. Personal learning is off by default; when explicitly enabled it retains aggregate input-to-candidate preferences on this Mac. See [personalization and privacy](docs/PRIVACY.md) for retained fields, expiry, pause, deletion, and storage limitations.

## English vocabulary maintenance

English source lists are maintained separately and merged into one offline vocabulary shared by English lookup and mixed decoding. The checked-in SCOWL snapshot, original SI words, and SI terminology are pinned and attributed. Additions, spelling/case corrections, exclusions, source tracing, deterministic generation, and monthly upstream audits are documented in [English vocabulary maintenance](docs/ENGLISH_VOCABULARY.md).

```sh
./scripts/vocabulary.sh build --check
./scripts/vocabulary.sh stats
./scripts/vocabulary.sh explain subtitle
```

## Personal learning

Open **SI Settings → Personalization** and enable **Personal learning**. Repeatedly choosing a candidate raises its position for that spelling. Explicit selections count more than accepting the default with Space; recent preferences matter more, with a 14-day half-life and a bounded ranking bonus. Other enabled languages and the original input remain available.

Saved single-language word choices also influence matching tokens inside longer compositions: learning `shi` → `时` can raise `我时` for `woshi`. Search keeps both a base-score beam and a personalized beam. Token preferences are averaged by the amount of input they cover and share the 32-point frequency cap with whole-input preferences; they are not added twice. This reuses existing aggregate records and does not split confirmed sentences into newly saved words. Personal/verbatim paths receive no learning bonus. Previous-word pairs still rerank generated candidates rather than internal tokens.

Whole-input and previous-word preferences apply before complete/prefix presentation limits. Prefix choices use only their consumed spelling. This lets saved choices influence the bounded shortlist before it is shown, while preserving base-ranked complete alternatives. Paths lost at an earlier search position can still be absent; this is bounded decoding rather than exhaustive sentence search.

Turning learning off pauses both updates and personalized ranking. **Manage Saved Preferences…** supports searching and forgetting individual entries; **Clear Saved Data…** removes all learned preferences. Entries expire after 90 days without use, with a maximum of 5,000 entries. Secure event input suppresses learning and personalized ranking. Literal commits, cancellation, focus changes, and shortcut passthrough are not learned. Candidate preview reflects preferences but never trains on preview text.

**Learn from the previous chosen word** is a separate, initially disabled option. It adds aggregate word-pair preferences, using only the previous confirmed candidate from the current typing session for up to five minutes. Cancellation, focus callbacks, host navigation, consent changes, and clearing reset this session context. No surrounding document text is read. Word pairs share the same 5,000-entry limit and 90-day expiry; the manager shows and searches their previous word. Preview uses frequency ranking without a preceding-word context.

Preferences are stored in a private local directory using atomic replacement. Writes are asynchronous and coalesced for 300 ms; normal termination flushes pending changes. A crash or forced termination can lose recent unsaved learning. Read/write failures appear in Settings; corrupt data is preserved until explicitly cleared. There is no cloud synchronization, full-text history, automatic phrase harvesting, or neural-model training.

## Personal phrases

Open **SI Settings → Personal Phrases → Manage Personal Phrases…** to add a code such as `xm` and the exact text to insert. Choose its candidate language and optionally prefer it for a full-code match. Phrases work even with learning off, respect enabled languages, and remain until manually deleted. They are not copied into learning records or used as preceding-word context.

The manager supports search, editing, deletion, clear, and additive JSON import/export, with at most 1,000 phrases. Imports preserve existing phrases and pin settings; invalid or over-capacity imports leave the dictionary unchanged. Saved codes also participate in longer Pinyin/mixed paths: saving `xm` → `小明` lets `woaixm` offer `我爱小明`. Any path containing a personal phrase stays excluded from automatic learning and previous-word context. Exported files contain phrase text and must be handled as personal data. See [phrase format and controls](docs/USER_PHRASES.md).

## Requirements

- macOS 14 or later.
- Xcode 26 or later with Swift 6.2 or later and the macOS SDK.
- No third-party runtime libraries or Apple Developer account are needed for an unsigned development build. English vocabulary data includes attributed SCOWL words.

## Get started

```sh
git clone https://github.com/caterm-dev/si.git
cd si
./scripts/test.sh
./scripts/build.sh
```

The application is built at `.build/xcode/Build/Products/Debug/SI.app`.

To work in Xcode, open `mac/SI.xcodeproj` and choose the shared **SI** scheme. The Run action passes `--settings` to show the settings window. Core tests are run through Swift Package Manager using `./scripts/test.sh`; they are not an Xcode test target.

The Xcode project defaults to ad hoc signing for local development. No personal signing team is committed to the project. For distribution, configure your own signing identity and team. The command-line build disables code signing; the installation script applies an ad hoc signature to the local copy.

## Install for local development

```sh
./scripts/install.sh
```

This builds SI, stages and verifies an ad hoc signed copy, and installs it in `~/Library/Input Methods/SI.app`. It then asks macOS to register the bundle and verifies exactly one selectable SI keyboard input source. It does not enable or select SI and never requires `sudo`. Stop any Xcode run first; if the installed SI process is running, select another input source and log out before replacing it.

1. After the installer reports `Verified: one selectable SI keyboard input source`, open Keyboard settings. If already open, close and reopen System Settings. Log out and back in only if SI remains missing.
2. Open **System Settings → Keyboard → Text Input → Edit → +**.
3. Look for **SI** under **English** and add it. macOS uses English as SI's primary discovery language; this does not select a runtime language mode or disable Chinese candidates inside SI.
4. Select **SI** in the input menu.
5. Open **SI Settings…** from the input menu to choose enabled languages.

You can also open the installed settings window with:

```sh
open "$HOME/Library/Input Methods/SI.app" --args --settings
```

Do not run the built and installed copies at the same time: they use the same InputMethodKit connection name. Input-source registration and typing behavior must be verified in a real login session; a successful build alone does not establish compatibility with every app.

If installation or discovery fails, retain the installer output and query only SI's registration without changing input sources:

```sh
xcrun swift scripts/register-input-source.swift --check "$HOME/Library/Input Methods/SI.app"
```

The corrected bundle/input-source identifier is `com.caterm.inputmethod.si`. The installer can replace the earlier `com.caterm.si` preview and keeps its backup. Language, punctuation, and learning-consent settings continue using the original `com.caterm.si` preferences domain; personal phrases and learning archives keep their existing locations. If an earlier SI source was manually added, remove its stale entry in Keyboard settings and add the corrected SI source.

To uninstall, select another input source, remove SI in Keyboard settings, then move `~/Library/Input Methods/SI.app` to Trash and log out. Installer backups, when present, are stored in `~/Library/Application Support/SI/Backups/` until you remove them.

## Keyboard behavior

| Key | During composition |
| --- | --- |
| Letters | Insert into the English/Pinyin composition at its caret |
| Apostrophe | Separate Pinyin syllables, e.g. `ni'hao` |
| Space | Commit the selected candidate; append a space for English, English-ending mixed candidates, or literal input |
| Return / Enter | Commit the original text without adding a newline |
| Left / Right | Move the composition caret by a whole character |
| Home / End | Move to the start/end of the composition |
| Up / Down, Page Up / Page Down | Navigate the native candidate window |
| 1–9 | Select candidates on the current native candidate page |
| Delete / Forward Delete | Remove the previous/next composition character at the caret |
| Escape | Cancel the composition |
| Common punctuation / Tab | Apply the configured composition-boundary behavior |
| A shortcut or code separator | Commit original spelling and pass the event through |

Outside composition, control keys and punctuation pass through. Shift and Caps Lock do not switch language modes. With both languages disabled, SI only offers the original text. The native candidate panel scrolls/pages through the full merged result; the engine does not discard another language's matches.

Number shortcuts select the currently visible candidate rows, including after scrolling or paging. Up/Down changes the highlighted choice, Page Up/Page Down moves by a page, and Space confirms the highlighted candidate. Left/Right edits the composition caret.

**Typing → Punctuation during composition** defaults to **Smart Chinese Punctuation**: common punctuation confirms a whole Chinese or mixed candidate, converting `.,;:!?()[]` when its ending is Chinese. **Confirm Candidate** keeps punctuation unchanged; **Keep Typed Text** retains the previous literal passthrough behavior. Both candidate-confirming options keep unselected English words/completions, incomplete personal codes, and code separators literal. Actively selecting an English candidate allows punctuation to confirm it. Prefix rows require Space or native selection rather than punctuation. Shortcuts and Return always keep spelling. Tab/punctuation confirmations never train learning. Quotes are not automatically paired, and punctuation after an already committed word remains unchanged.

## Project layout

```text
mac/SI/App/             App lifecycle and InputMethodKit server
mac/SI/InputMethod/     Client events, marked text, and native candidate window
mac/SI/Settings/        SwiftUI language settings and candidate preview
mac/SI/Core/            UI-independent candidate engine and input session
mac/SI/Storage/         Actor-isolated local learning and personal-phrase persistence
mac/Support/           Input-method bundle metadata
Tests/                 Swift Testing coverage for core, storage, and settings
scripts/               Build, test, and local installation commands
docs/                  Architecture, manual checks, and roadmap
```

The Swift package and Xcode app compile the same core source files. There is no separate copy of the engine to keep in sync.

## Website

The static landing page supports English and Simplified Chinese, with an accessible scripted input demonstration. Build it with `node scripts/build-website.mjs`; see [website development and GitHub Pages deployment](docs/WEBSITE.md) for preview, localization, download updates, and custom-domain setup.

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) and the [architecture](docs/ARCHITECTURE.md). Keep code, UI copy, documentation, issue reports, and pull requests in English. Language data and user input naturally retain their original scripts.

See the [roadmap](docs/ROADMAP.md) for planned work and [manual verification](docs/TESTING.md) for host-app checks. GitHub Actions builds the macOS app and runs core tests on pushes and pull requests.

`./scripts/benchmark.sh` measures Release-mode candidate generation across thirteen synthetic scenarios with 5,000 saved preferences and 1,000 personal phrases, including relevant learned tokens and long Unicode/emoji expansions. It emits JSON with timings and synthetic candidate fingerprints; `--resources` separately reports CLI-process resource usage on stderr. This measures the in-process engine, not total key-to-screen latency. See [dictionary provenance and decoder limits](docs/DICTIONARIES.md) and the [latest verification checkpoint](docs/VERIFICATION.md).

## License

SI is licensed under the GNU General Public License, version 3. See [LICENSE](LICENSE). The repository's existing license is preserved. The English vocabulary includes SCOWL data with its original notices; see [data provenance](docs/DICTIONARIES.md). Additional dictionaries or language models must have compatible licenses and documented provenance.
