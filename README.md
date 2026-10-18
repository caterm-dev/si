# SI

**One input. Every language.**

SI is an open-source macOS input method built around one idea: choose the languages you use in Settings, then type without switching between language modes. Candidates from enabled languages appear together, including ambiguous matches. The original text always remains available.

> **Status: development scaffold.** SI includes InputMethodKit integration and a small, original demonstration vocabulary. It is not yet a production Chinese/English input method. Full Pinyin decoding, automatic mixed-language segmentation, contextual ranking, and broad app compatibility are planned.

## How it works

Enable **English** and **Chinese (Simplified)** once. SI queries both providers for each composition:

| Input | Example candidates |
| --- | --- |
| `shi` | `是`, `时`, `事`, `十`, `ship`, `shirt`, `shi` (as typed) |
| `he` | `he`, `和`, `喝`, `河`, `hello`, `help`, `her`, `he` (as typed) |
| `nihao` | `你好`, `nihao` (as typed) |

Selecting `你好` and then typing `world` produces mixed text without changing language modes. In this scaffold, each word or phrase is committed explicitly; an unbroken input such as `nihaoworld` is not automatically segmented yet.

All processing is local. SI has no network client, analytics, keystroke logging, or cloud dependency. Language preferences are saved in UserDefaults; typed content is held only in the current composition session and is sent to the active application when committed.

## Requirements

- macOS 14 or later.
- Xcode 26 or later with Swift 6.2 or later and the macOS SDK.
- No third-party dependencies or Apple Developer account are needed for an unsigned development build.

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

This builds SI, stages and verifies an ad hoc signed copy, and installs it in `~/Library/Input Methods/SI.app`. It never requires `sudo`. If SI is already running, select another input source and log out before replacing the installed copy.

1. Log out and back in if SI does not appear immediately.
2. Open **System Settings → Keyboard → Text Input → Edit → +**.
3. Look for **SI** under **Chinese, Simplified** and add it. macOS uses a primary language for discovery; this does not select a runtime language mode inside SI.
4. Select **SI** in the input menu.
5. Open **SI Settings…** from the input menu to choose enabled languages.

You can also open the installed settings window with:

```sh
open "$HOME/Library/Input Methods/SI.app" --args --settings
```

Do not run the built and installed copies at the same time: they use the same InputMethodKit connection name. Input-source registration and typing behavior must be verified in a real login session; a successful build alone does not establish compatibility with every app.

To uninstall, select another input source, remove SI in Keyboard settings, then move `~/Library/Input Methods/SI.app` to Trash and log out. Installer backups, when present, are stored in `~/Library/Application Support/SI/Backups/` until you remove them.

## Keyboard behavior

| Key | During composition |
| --- | --- |
| Letters | Extend the English/Pinyin composition |
| Apostrophe | Separate Pinyin syllables, e.g. `ni'hao` |
| Space | Commit the selected candidate; append a space for English or literal input |
| Return / Enter | Commit the original text without adding a newline |
| Arrow keys | Navigate the native candidate window |
| 1–9 | Select candidates on the current native candidate page |
| Delete | Remove the last composition character |
| Escape | Cancel the composition |
| Punctuation, Tab, or a shortcut | Commit the original text and pass the event to the application |

Outside composition, control keys and punctuation pass through. Shift and Caps Lock do not switch language modes. With both languages disabled, SI only offers the original text. The native candidate panel scrolls/pages through the full merged result; the engine does not discard another language's matches.

## Project layout

```text
mac/SI/App/             App lifecycle and InputMethodKit server
mac/SI/InputMethod/     Client events, marked text, and native candidate window
mac/SI/Settings/        SwiftUI language settings and candidate preview
mac/SI/Core/            UI-independent candidate engine and input session
mac/Support/           Input-method bundle metadata
Tests/SICoreTests/      Swift Testing coverage for the shared core
scripts/               Build, test, and local installation commands
docs/                  Architecture, manual checks, and roadmap
```

The Swift package and Xcode app compile the same core source files. There is no separate copy of the engine to keep in sync.

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) and the [architecture](docs/ARCHITECTURE.md). Keep code, UI copy, documentation, issue reports, and pull requests in English. Language data and user input naturally retain their original scripts.

See the [roadmap](docs/ROADMAP.md) for planned work and [manual verification](docs/TESTING.md) for host-app checks. GitHub Actions builds the macOS app and runs core tests on pushes and pull requests.

## License

SI is licensed under the GNU General Public License, version 3. See [LICENSE](LICENSE). The repository's existing license is preserved. Any future dictionaries or language models must have compatible licenses and documented provenance.
