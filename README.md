# SI

**One input. Every language.**

SI is an open-source macOS input method built around one idea: choose the languages you use in Settings, then type without switching between language modes. Candidates from enabled languages appear together, including ambiguous matches. The original text always remains available.

> **Status: development preview; Chinese engine migration in progress.** The current worktree implements the Chinese decoder in Swift using MSIME-derived lookup, word-lattice and word-context algorithms, with a pinned dictionary maintained by SI. Debug and Release builds have passed. The remaining regression suite passes after ten failing tests were removed at the user's request; those underlying behaviors remain unresolved. See the current validation record. Chinese quality parity and host compatibility remain unproven. English lookup and bounded Chinese/English lexical paths are connected; full regressions and host verification remain incomplete.

## How it works

Enable **English** and **Chinese (Simplified)** once. SI queries both providers for each composition:

| Input | Example candidates |
| --- | --- |
| `shi` | `是`, `时`, `事`, `十`, `ship`, `shirt`, `shi` (as typed) |
| `he` | `he`, `和`, `喝`, `河`, `hello`, `help`, `her`, `he` (as typed) |
| `nihao` | `你好`, `nihao` (as typed) |
| `iwanttobuild` | `I want to build`, `iwanttobuild` (as typed) |
| `woxiangyaodeploy` | `我想要deploy`, `woxiangyaodeploy` (as typed) |

The Chinese path queries exact full readings, syllable prefixes and initials, then constructs sentence candidates with a bounded word lattice. Corpus-derived word bigrams participate in search and word trigrams rescore surviving paths. Lexical matches, generated sentences and completions compete by a shared score. Up to 32 complete minimum-syllable cuts share sentence search, so ambiguous boundaries such as `wo / xian / gan / zhao` and `wo / xiang / an / zhao` compete using dictionary frequency and word context; `woxianganzhao` has `我想按照` as its leading complete sentence; prefixes compete separately by their own scores in the merged list. Apostrophes constrain syllable boundaries; prefix choices retain the exact unconsumed source spelling. SI deliberately lowers the extra single-character cost to let dictionary frequency compete more strongly with segmentation structure. The residual cost discourages excessive character splitting. This differs from the upstream scoring formula and does not establish MSIME-equivalent quality.

English word lookup and continuous English segmentation remain available. With both languages enabled, a bounded lexical lattice also joins complete Pinyin words and English words in either direction, including `woxiangyaodeploy` → `我想要deploy`, preserved English casing, interleaved words and a completed final English word. It uses the same packaged dictionaries and relative weight unit; pure Chinese sentences retain their existing decoder. Exact English words and fully lexical English sentences keep their English identity. Chinese, English and mixed whole choices now compete by the same word, spelling and language-transition costs, with available Chinese context and opted-in learning bonuses. Full Pinyin syllables and complete English words receive stronger spelling weight than incomplete observations: bilingual `ma` now leads with `吗`, while English completions remain available. This heuristic can favor fully spelled word sequences over an unfinished English word. No language category has a reserved front position. For `ling`, `零` scores above `里NG`; English completions such as `lingo` remain eligible by score. See [candidate ranking](docs/UNIFIED_RANKING.md). Mixed initials, incomplete Chinese-tail prediction and broad language-boundary detection remain limited. The exact original input remains an explicit candidate, including unknown input and configurations with all languages disabled.

Whole candidates and prefixes compete by the same effective score in the engine. The window uses a 27-choice ordinary shortlist and additionally retains every generated Chinese dictionary character, with further pages beyond that budget. For a composition led by an assembled sentence or fragment, it displays up to four such hypotheses first, then only single-character or single-word choices. Extra sentences and multiword fragments stay in the full engine results instead of appearing on later pages. Required first choices for enabled language/mixed identities count toward the four-hypothesis limit. Word-led queries such as `ling` and `xianshi` keep engine order among retained choices. Lexical-unit metadata, rather than output length, distinguishes words from constructed fragments; explicit personal phrases and punctuation choices remain eligible. App History keeps its separate placement after the first two whole choices, and the exact original input remains last. Scores are unchanged. Prefix comparison accounts for the rest of the current input and an extra confirmation while preserving the word's own frequency score. Choosing `比如` from `biruzhege` consumes only `biru`, leaving `zhege` editable. With `sheguofennudehai`, word choices remain available after the leading hypotheses, allowing `涉` → `过` → `愤怒` → `的` → `海` to be chosen individually. Prefix choices show a small arrow; tooltips and accessibility descriptions retain the exact consumed spelling. Return commits exact remaining spelling. Provisional hints may change when full results arrive. Live host compatibility remains unverified.

All input processing is local. SI has no analytics, keystroke logging, or cloud dependency for typing. Optional, user-initiated software update checks contact SI's download service without sending input or personal phrases. Language and learning settings are saved in UserDefaults. App vocabulary and app history are off by default. Independent opt-ins allow local aggregate preferences or app-scoped history completion; nothing is uploaded. See [personalization and privacy](docs/PRIVACY.md) for retained fields, expiry, pause, deletion, and storage limitations.

## Interface language

The app supports English and Simplified Chinese. Settings, input-menu actions, candidate descriptions and accessibility labels follow the macOS preferred app language, with English as the fallback. Set a preferred language for SI in **System Settings → General → Language & Region → Applications**, where available, then restart SI normally for the change to take effect. Do not launch a second copy of the input method.

Interface language is independent of the English/Chinese input-language switches. Changing it does not change candidates, committed text, personal phrases, learning consent or saved data. The compact E/C/A punctuation badges retain their existing identifiers; their full descriptions are localized.

## Vocabulary maintenance

Chinese data is now maintained under [Data/Chinese/MSIME](Data/Chinese/MSIME/README.md): pinned MSIME source snapshots, provenance, reading corrections and an SI-owned additions/exclusions overlay generate one read-only SQLite dictionary used by both the package and app. Word-context tables are pinned separately. All resource downloads are explicit maintainer actions; typing never downloads data. The algorithm is Swift, with no Rust dependency.

```sh
python3 scripts/msime_dictionary.py build
python3 scripts/msime_dictionary.py build --check
python3 scripts/english_dictionary.py build
python3 scripts/english_dictionary.py build --check
python3 scripts/msime_dictionary.py fetch-context
```

The Chinese dictionary currently contains 953,625 unique text/reading entries after excluding 85 private-use character readings through the SI overlay. Its coverage, new ranking and optional-learning interactions remain unverified. The former Chinese Swift tables, direct Rime imports and their maintenance pipeline have been removed. English now has the same weighted-snapshot, SI-overlay and read-only SQLite workflow, with 63,602 retained word forms; see [English maintenance](docs/ENGLISH_VOCABULARY.md). Both databases share their schema, reader and dictionary-relative weight unit, defined in `Data/DictionaryFormat.json`. Complete candidates share a heuristic cost formula; this does not establish calibrated language probabilities. Public corrections and additions belong in `Data/Chinese/MSIME/si-entries.json` and `Data/English/SI/si-entries.json`. Private personal phrases and learning archives are preserved. [The implementation plan](docs/IMPLEMENTATION_PLAN.md) tracks unfinished correction, optional neural reranking and parity work.

## Automatic prefix confirmation

Enable **Automatically confirm stable prefixes** in **SI Settings → Typing** to let SI confirm leading Chinese words while you continue typing or pause. It is off by default. SI keeps at least four output characters editable during continuous typing, or two after a pause of at least 1.8 seconds; complete-word boundaries can leave a longer ending. Only the confirmed source spelling is consumed, and the remaining exact spelling stays marked and editable without an extra space.

Automatic confirmation requires matching source/output boundaries across nearby full-search alternatives. Continued typing must also preserve the prefix across multiple results with additional input. A pause relaxes the ending length, but requires a prefix of at least two characters and does not override disagreement between candidates. Ambiguous input can remain entirely editable. Provisional hints never trigger confirmation. English/mixed leaders, uppercase/code-like spelling, personal phrases and unrecognized spans are excluded. These are conservative local heuristics, not a guarantee of sentence meaning or a way to predict whether later typing will turn a spelling into an identifier.

Editing, moving the caret, navigating/expanding candidates, or crossing a host boundary cancels automatic confirmation; fresh typing at the composition end starts new evidence. Settings changes, secure input, cancellation and stale asynchronous results cannot authorize a pending confirmation. Each pause can confirm at most once until more input arrives. Automatic confirmation does not train app vocabulary and saves no typing history. Return and shortcuts preserve only the remaining spelling once a prefix has been committed; editing already committed text uses the host application's normal editing tools. Native timer/focus behavior still requires the checks in [testing](docs/TESTING.md#automatic-prefix-confirmation).

## Direct input by application

Open **SI Settings → Direct Input by Application → Manage Direct Input…** and turn on direct input for apps such as Terminal. Every app uses normal SI conversion by default. The searchable list discovers apps in the standard system, local and user Applications folders, plus running apps, and displays each app's system icon beside its name. **Add Application…** lets you select an `.app` stored elsewhere; **Refresh** rescans the list. Rules are saved locally by bundle identifier, and enabled rules remain listed with a generic application icon when an app is no longer installed.

In a selected app, SI passes key events to the host without composition, candidates, punctuation conversion or automatic spacing. Space, Tab, Return, navigation and shortcuts belong to the host. If the rule takes effect during composition, SI inserts only the exact pending spelling once and rejects old candidate results and automatic-confirmation tasks. SI does not learn vocabulary or record history while direct input is enabled; existing saved data remains until deleted. Turning direct input off restores ordinary conversion and the app's independently configured learning/history consent.

Rules use the InputMethodKit client's application identity, not the foreground process. A browser rule applies to every tab and input field; an editor rule includes its embedded terminal. It cannot distinguish an address from a search in a combined address bar. No Accessibility or Input Monitoring permission is requested, and SI remains the selected system input source. Native host behavior still requires the [direct-input manual checks](docs/TESTING.md#direct-input-by-application).

## App vocabulary and history

Open **SI Settings → App Vocabulary and History**. Two independent options are off by default:

- **Learn vocabulary separately for each app** counts confirmed candidates, including default Space acceptance, only for the client application's bundle identifier. It retains the consumed spelling, candidate, use count, decaying preference and original candidate score. Saved choices supplement the base dictionary and influence that app's ranking, including eligible words within longer compositions. Confirming a sentence does not automatically save its component words. Literal, personal/verbatim, delimiter, automatic-confirmation and history candidates do not train this vocabulary. This is the only automatic vocabulary-learning feature. Turning it off, or pausing it for an app, returns to base ranking; there is no shared-learning fallback.
- **Remember input history separately for each app** accumulates SI commits and printable passthrough text in a client-local draft. An unmodified Return/keypad Enter that reaches the host saves a deduplicated input unit with its source spelling, output, application, language identities, use count and last-use time. A Return consumed to commit original composition spelling does not save or send the unit. Shift/shortcut Return is not a history delimiter. This can retain sensitive literal text; it is separate consent from vocabulary learning.

Type the beginning of a saved spelling to see up to three **App History** completions with a clock symbol after the engine's first two whole choices. Confirm using the ordinary number, mouse or candidate navigation/Space controls. A completion inserts only the uncommitted output suffix, preserves its exact bytes, and adds no automatic English space. Already confirmed prefixes can participate in matching while a new nonempty composition is typed. Empty composition still yields no candidates; history is not an inline ghost-text feature. Prefix matching is bounded and does not infer that a message was sent or a command executed.

**Manage App Data…** offers application filtering, search, per-entry Forget, independent per-app pause/resume, and clearing vocabulary or history for one app or all apps. **Clear All App Data…** erases both archives together, without clearing explicit phrases or legacy shared learning. App vocabulary retains at most 5,000 entries across apps and expires after 90 days without use; history retains at most 1,000 entries across apps and expires after 30 days. Source spelling and output are each bounded to 4,096 UTF-8 bytes for a history unit. Vocabulary retains the existing learning limits of 128 spelling bytes and 512 output bytes.

History drafts expire after five minutes without activity. Editing committed text, navigation outside composition, shortcuts/paste, Escape, host focus callbacks, consent/configuration changes, secure input, automatic prefix confirmation and personal/verbatim paths discard a draft. After an editing boundary, recording resumes at the next unmodified host Return; a new client starts a new draft. SI reads no document or clipboard text. Where a host supplies selection offsets, unexpected caret movement also invalidates the draft. Unreported host edits, unsupported offsets, missing focus events and application text transformations can still make observed input differ from the final document. Browser tabs/sites share the browser application's scope. Native app compatibility and VoiceOver checks remain unverified; see [manual checks](docs/TESTING.md#app-vocabulary-and-history).

The former **Personal learning** section and **Learn from the previous chosen word** option have been removed. App vocabulary reuses the core ranking model, including its 14-day half-life and 32-point frequency cap. Chinese single-character preferences affect only their own spelling; Chinese words with at least two characters and English words can also influence matching tokens in longer compositions. Token/whole bonuses share their cap, base and personalized search beams remain separate, and explicit syllable boundaries and consumed prefix spelling are preserved. No component words are automatically harvested from confirmed sentences.

Old shared preferences have no application identity, so they are not imported into app vocabularies. The retired `SI/Personalization/preferences-v1.json` archive is no longer loaded, updated or used for ranking; its old consent flags are ignored. If the file exists, **Delete Old Shared Learning Data…** appears in the app-data section. It deletes only that retired archive and its consent flags after confirmation, without affecting app data or explicit personal phrases. No files are automatically deleted during this feature removal. The retired archive no longer receives automatic expiry cleanup; delete it through this control when no longer needed.

## Personal phrases

Open **SI Settings → Personal Phrases → Manage Personal Phrases…** to add a code such as `xm` and the exact text to insert. Choose its candidate language and optionally prefer it for a full-code match. Phrases work even with learning off, respect enabled languages, and remain until manually deleted. They are not copied into learning records or used as preceding-word context.

The manager supports search, editing, deletion, clear, and additive JSON import/export, with at most 1,000 phrases. Imports preserve existing phrases and pin settings; invalid or over-capacity imports leave the dictionary unchanged. Saved codes also participate in longer Pinyin/mixed paths: saving `xm` → `小明` lets `woaixm` offer `我爱小明`. Any path containing a personal phrase stays excluded from automatic learning and previous-word context. Exported files contain phrase text and must be handled as personal data. See [phrase format and controls](docs/USER_PHRASES.md).

## Requirements

- macOS 14 or later.
- Xcode 26 or later with Swift 6.2 or later and the macOS SDK.
- Xcode resolves the pinned Sparkle 2.10.0 update framework on the first app build; no Apple Developer account is needed for an unsigned development build. Chinese vocabulary comes from pinned MSIME sources and context artifacts. English retains attributed SCOWL, CSpell and Rime Ice selections, with wordfreq frequency data.

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

This builds the optimized **Release** app, stages and verifies an ad hoc signed copy, and installs it in `~/Library/Input Methods/SI.app`. Use `./scripts/install.sh Debug` only when debugging an installed input method; Debug disables compiler optimization and is not representative of typing performance. The installer then asks macOS to register the bundle and verifies exactly one selectable SI keyboard input source. It does not enable or select SI and never requires `sudo`. Stop any Xcode run first; if the installed SI process is running, select another input source and log out before replacing it.

To automatically stop SI and reinstall during development, run:

```sh
./scripts/reinstall.sh          # Release (default)
./scripts/reinstall.sh Debug
```

This stops processes named exactly `SI` owned by the current user, waits up to five seconds, and uses SIGKILL if necessary before calling the existing installer. Pending composition or unsaved learning may be lost. The installer's running-process checks, signing, backup, rollback, and registration remain in effect. Select another input source and stop any Xcode run first to avoid SI restarting during the build; if it restarts, installation aborts rather than replacing a running app. The script does not change enabled or selected input sources or force logout.

1. After the installer reports `Verified: one selectable SI keyboard input source`, open Keyboard settings. If already open, close and reopen System Settings. Log out and back in only if SI remains missing.
2. Open **System Settings → Keyboard → Text Input → Edit → +**.
3. Look for **SI** under **English** and add it. macOS uses English as SI's primary discovery language; this does not select a runtime language mode or disable Chinese candidates inside SI.
4. Select **SI** in the input menu.
5. Open **SI Settings…** from the input menu to choose enabled languages.

SI uses a rounded template badge with transparent SI lettering, allowing macOS to tint the background shape for the menu bar and selected menu rows. Regenerate the original asset with `xcrun swift scripts/generate-icons.swift`.

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

## Check for updates

In the installed Release app, choose **Check for Updates…** from the SI input menu or **SI Settings → Software Updates**. SI uses Sparkle, as Caterm does, with a separate SI update feed. Checking is manual; background checks, automatic installation and system-profile submission are disabled. Sparkle verifies the update signature and asks before downloading/installing. Save your work and finish composing before installing; SI restarts and flushes pending personal-data writes through its normal termination path. If typing does not resume, log out and back in. Debug builds and copies outside `~/Library/Input Methods/SI.app` show an explanation in Settings and disable checking.

Versions without the updater need one manual installation of an updater-enabled release. A check requires a published SI Sparkle feed; adding this implementation does not publish a release or establish native update/host compatibility. See [release and update configuration](docs/RELEASING.md#in-app-updates).

## Package and publish a DMG

```sh
./scripts/package-dmg.sh --dry-run   # Inspect Universal Release packaging
./scripts/package-dmg.sh             # Local ad hoc signed preview
./scripts/release.sh --dry-run       # Detect signing identities and inspect publication
./scripts/release.sh                 # Increment patch/build, commit versions, notarize and publish
./scripts/release.sh --no-bump       # Publish/retry the current version without incrementing
```

Publication uses Caterm's public R2 bucket and download domain under the separate `si/` prefix. It selects a unique Developer ID Application identity valid under macOS's code-signing policy, then requires a valid Installer identity from that team. It never switches to another team to obtain a complete pair. The defaults are Caterm's `caterm-notary` notarization profile and `caterm-r2` AWS profile. The notarization profile must belong to the selected signing team; flags/environment override the defaults, and ambiguous or missing identities stop publication. A clean committed checkout is required. Open `Install SI.pkg` inside the DMG to install in `~/Library/Input Methods`; the native macOS Installer ends with **Log Out** to finish registration. Save your work, click the button and log back in; a full Mac restart is not required by this installer. Existing apps are backed up and a running SI blocks replacement. See [release configuration, artifacts and retry behavior](docs/RELEASING.md). Adding these scripts does not mean a public release has been published or host compatibility has been verified.

Each new release increments the last version component (`0.1.0` → `0.1.1`) and internal build number, then commits only the Xcode version file before building. Preflight failures leave versions unchanged; retries of a pending release at the same commit/architecture reuse its version. `--dry-run` prints the planned increment without changing files or Git history. See the release guide for `--no-bump`, retry state and multiple architectures.

## Keyboard behavior

| Key | During composition |
| --- | --- |
| Letters | Insert into the English/Pinyin composition at its caret |
| Apostrophe | Separate Pinyin syllables, e.g. `ni'hao` |
| Space | Commit the selected candidate; append a space for English, English-ending mixed candidates, or literal input |
| Return / Enter | Commit the original text without adding a newline |
| Left / Right | Select the previous/next candidate when collapsed; move columns when expanded |
| Home / End | Move to the start/end of the composition |
| Up / Down | Down expands first; move rows in the expanded grid |
| Page Up / Page Down | Change whole pages: six choices collapsed, 24 expanded |
| 1–6 | Select candidates on the current highlighted row/page |
| Delete / Forward Delete | Remove the previous/next composition character at the caret |
| Escape | Cancel the composition |
| Punctuation / symbols | Stay editable in the composition by default; optional punctuation confirmation is configurable |
| Tab | Apply the configured composition-boundary behavior |
| A shortcut | Commit original spelling and pass the event through |

Outside composition, control keys and punctuation pass through by default. Enable Show punctuation candidates in Settings → Typing to start common punctuation compositions with language-labeled alternatives for enabled languages. Shift and Caps Lock do not switch language modes. With both languages disabled, SI only offers the original text. SI's nonactivating AppKit candidate panel starts as a horizontal single line with up to six numbered choices. Short candidates such as `a` remain visible beside their numbers. Press Down Arrow or click the chevron to expand to four rows of six candidates, showing up to 24 choices at once. The entire four-row grid is one page; numbers 1–6 act on the highlighted row. Other displayed rows remain directly clickable. The first row uses the same compact candidate cells and defines the six column widths; all later rows align their numbers and text with those columns. Narrow screens shrink the shared columns to fit, with full text retained in tooltips and accessibility labels. Click the top-right chevron to collapse again. The first Down Arrow only expands and preserves the selected candidate; subsequent Down/Up presses move rows, Left/Right moves columns, and Page Up/Down changes whole grid pages. Expansion keeps the current selection and lasts until the composition ends; the next composition starts collapsed. The same shortlist is used in both layouts: six choices per collapsed page or 24 per expanded page, including each matching language identity and the exact original input. All generated Chinese dictionary characters remain pageable. Complete-syllable character lookup and character prefixes are exempt from the old preview/24-prefix limits; other word, initial/completion and sentence search remains bounded.

Number shortcuts 1–6 select within the currently highlighted row in both layouts. Other rows use dimmer numbers until they become active. Left/Right selects candidates in the collapsed strip; Down expands it without changing selection. In the expanded grid, Left/Right moves within a row and Up/Down moves between rows while preserving the column where possible. Row/column movement stops at page boundaries. Page Up/Page Down and the footer buttons change whole pages (six choices collapsed, 24 expanded), preserving the cell position where the destination has it. Space confirms the highlighted candidate. Mouse-wheel and trackpad scrolling do not change pages or selection. Home/End continue editing the composition caret.

Ordinary typing updates marked spelling before searching candidates off the main thread. A separate bounded search supplies provisional hints for the latest spelling while the full search runs, so an obsolete full search does not hold up every update. Both stages use the same decoder and maintain one running request plus one latest replacement per client. Provisional hints have narrower lexical coverage and may change when full results arrive; they do not replace the final candidate set. Only matching composition revisions may update the window. Pending hints refresh the rows without hiding the panel or shrinking its current size; mouse, page and expansion controls remain disabled until full results arrive. Space, digits, candidate navigation, and optional punctuation confirmation resolve full current candidates before selecting; these confirmation boundaries can still wait for a search. Return, Escape, and shortcuts preserve/cancel spelling without waiting.

The candidate window uses a slim warm-neutral strip, a soft peach selection pill and an orange selected number. Text remains dark in the light appearance, with a coordinated dark palette. Candidate buttons keep numbers close to their text and fit their content rather than stretching across unused space. Small arrow, pin and text symbols distinguish prefix, personal and typed-text sources in both layouts. Punctuation candidates show a small E (English) or C (Chinese) badge immediately after the text in both layouts; the exact original spelling shows A (As Typed). Full language/source details remain in tooltips and accessibility labels. The system Increased Contrast preference adds a stronger outline; page controls appear only when more than one page is available.

The panel anchors below the beginning of the marked composition, using InputMethodKit's inline-session coordinates, and moves above it when space is limited. Document-range coordinates are a fallback only after checking the returned range. A temporary geometry failure can reuse the last valid position in that composition; fresh inline coordinates replace earlier fallbacks, and without reliable geometry the panel stays hidden. Host-specific positioning still requires manual verification.

**Typing → Punctuation during composition** defaults to **Keep Composing**: punctuation and symbols stay in the marked spelling so `example.com`, `user@example.com`, `foo/bar`, and `nihao,world` can be typed and edited as one composition. ASCII period `.` stays editable under every policy, even after candidate navigation; typing it never confirms a candidate or automatically converts it to `。`. With punctuation candidates enabled, an explicit selection can choose `。`. Non-confirming symbols also remain editable in the optional policies. Return commits the exact spelling; Space/numbers/mouse still confirm the current candidate, and Escape cancels the entire composition. Apostrophes retain their Pinyin boundary meaning. Digits remain candidate shortcuts rather than general numeric entry. Tab commits literal spelling and passes through in Keep Composing. **Smart Chinese Punctuation** and **Confirm Candidate** remain optional confirmation policies; saved explicit choices are preserved. They confirm supported punctuation/Tab with existing English, prefix and personal-code safeguards; smart mode converts `,;:!?()[]` after Chinese endings. Unmapped symbols outside composition pass through, and shortcuts preserve the exact spelling. Symbol insertion does not train learning; optional delimiter confirmations do not train either. Quotes are not automatically paired.

**Settings → Typing → Show punctuation candidates** is off by default and saves your explicit choice. It controls the input method independently of the composition punctuation policy. When enabled, common punctuation keys `, . / ; ' " : ! ? ( ) [ ]` offer English and Chinese alternatives for the enabled languages. For example, `,` offers `,` (English), `，` and `、` (Chinese), plus the exact original `,` (As Typed); `.` offers `.` and `。`/`…`. These candidates use the usual Space, numbers and mouse selection and never append an extra space. In Keep Composing, a trailing punctuation key also offers complete word/sentence candidates with that punctuation, such as `nihao,` → `你好,` / `你好，` / `你好、`; unfinished completions and prefix-only choices are excluded. Typing more letters keeps the original marked spelling editable, so domains, paths and code can continue without selecting punctuation. Apostrophes inside a composition remain Pinyin separators; curly single-quote choices are offered when the apostrophe starts a composition. Consecutive punctuation and unknown word prefixes retain exact spelling without combinatorial punctuation expansion. Punctuation choices do not train vocabulary or previous-word context, and personal/verbatim derivations keep their archive exclusions. Native host routing and VoiceOver verification remain pending.

## Project layout

```text
mac/SI/App/             App lifecycle and InputMethodKit server
mac/SI/InputMethod/     Client events, marked text, selection state, and AppKit candidate window
mac/SI/Settings/        SwiftUI language, typing, and app-data settings
mac/SI/Core/            UI-independent candidate engine and input session
mac/SI/Storage/         Actor-isolated local learning and personal-phrase persistence
mac/Support/           Input-method bundle metadata
Tests/                 Swift Testing coverage for core, storage, and settings
scripts/               Build, test, and local installation commands
docs/                  Architecture, manual checks, and roadmap
llm/                   Offline spelling-to-text training experiments (not loaded by the app)
```

The Swift package and Xcode app compile the same core source files. There is no separate copy of the engine to keep in sync.

## Model training experiments

[The independent `llm/` framework](llm/README.md) supports training a randomly initialized 0.403B encoder–decoder for Pinyin conversion, English preservation/correction and explicit mixed pairs. Its editable sources are [static CSV files](llm/data/csv/README.md): `train/`, `validation/` and `test/` directories choose the split, and filenames such as `city.csv` and `company.csv` choose source groups. Preparation freezes maintained rows and source hashes without generating sentences, Pinyin, typos or random splits. The obsolete generated datasets, seed/generator and importer files have been removed. Existing trained weights are retained for inference; new training uses versioned CSV bundles. Representative quality and native deployment remain unverified; no trained model is integrated into SI. App vocabulary, history and personal phrases are not training sources.

Each preset script performs one task: run `./llm/scripts/setup.sh` for the environment, `./llm/scripts/data.sh` for CSV preparation, `./llm/scripts/run.sh` for 0.4B training on MPS, then separately run `validation.sh`, `test.sh`, `infer.sh` or `export.sh` as needed. Shared paths and parameters are in `llm/scripts/defaults.sh`; no stage launches the next one. The scripts use `llm/.venv` without activation and accept explicit argument overrides. Use `check.sh` and the small CPU `smoke.sh` for framework checks. See [the framework guide](llm/README.md) for preset locations and new-run/resume instructions.

The maintained collection contains 50,000 unique samples: 47,339 training, 1,361 validation and 1,300 test. Chat and vocabulary categories are consolidated into one `chat.csv` and `words.csv` per split. The [50,000-sample expansion](llm/data/csv/EXPANSION_50K.md) adds original synthetic Chinese, English, mixed and typo pairs while preserving every original sample and validation/test file. These template combinations do not establish real-world conversion quality. Existing prepared datasets and training runs keep their frozen source snapshots.

## Website

The static website supports English and Simplified Chinese, with dedicated Privacy and Terms pages and an accessible scripted input demonstration. It highlights offline, on-device typing while explaining the separate user-initiated update connection and independently opted-in local data. Its download section offers separate Apple Silicon (arm64) and Intel (x86_64) images from the published R2 channels, each with its matching checksum and source archive. Build it with `node scripts/build-website.mjs`; see [website development and GitHub Pages deployment](docs/WEBSITE.md) for preview, localization, download updates, and custom-domain setup.

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) and the [architecture](docs/ARCHITECTURE.md). Keep code, source localization keys, documentation, issue reports, and pull requests in English. App translations, language data and user input retain their original scripts.

See the [roadmap](docs/ROADMAP.md) for planned work and [manual verification](docs/TESTING.md) for host-app checks. GitHub Actions builds the macOS app and runs core tests on pushes and pull requests.

The `./scripts/benchmark.sh` harness covers synthetic Chinese/mixed scenarios, including `woxiangyaodeploy`, saved preferences and personal phrases, English lookup, and synchronous/deferred edit costs. It has been run for the mixed lexical integration; initialization is lazy on candidate workers and older timing figures do not describe this version. Benchmark scenarios and quality fixtures still need reconciliation with the new policy. See [dictionary provenance and decoder limits](docs/DICTIONARIES.md), [the MSIME algorithm study](docs/MSIME_ALGORITHM.md), and [verification status](docs/VERIFICATION.md).

## License

SI is licensed under the GNU General Public License, version 3. See [LICENSE](LICENSE). The repository's existing license is preserved. The vocabularies include SCOWL, MIT-licensed CSpell lists and selected Rime Ice data; wordfreq-derived frequency data retains CC-BY-SA-4.0 attribution and redistribution terms. See [data provenance](docs/DICTIONARIES.md). Additional dictionaries or language models must have compatible licenses and documented provenance.
