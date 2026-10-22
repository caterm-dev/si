# SI

**One input. Every language.**

SI is an open-source macOS input method built around one idea: choose the languages you use in Settings, then type without switching between language modes. Candidates from enabled languages appear together, including ambiguous matches. The original text always remains available.

> **Status: development preview; Chinese engine migration in progress.** The current worktree implements the Chinese decoder in Swift using MSIME-derived lookup, word-lattice and word-context algorithms, with a pinned dictionary maintained by SI. Debug and Release builds now pass, but the full regression suite still fails; see the current validation record. Chinese quality parity and host compatibility remain unproven. English lookup is kept separate; mixed lexical paths will return after the Chinese baseline is established.

## How it works

Enable **English** and **Chinese (Simplified)** once. SI queries both providers for each composition:

| Input | Example candidates |
| --- | --- |
| `shi` | `是`, `时`, `事`, `十`, `ship`, `shirt`, `shi` (as typed) |
| `he` | `he`, `和`, `喝`, `河`, `hello`, `help`, `her`, `he` (as typed) |
| `nihao` | `你好`, `nihao` (as typed) |
| `iwanttobuild` | `I want to build`, `iwanttobuild` (as typed) |

The Chinese path queries exact full readings, syllable prefixes and initials, then constructs sentence candidates with a bounded word lattice. Corpus-derived word bigrams participate in search and word trigrams rescore surviving paths. Exact lexical matches have a protected position before generated sentences and completions. Apostrophes constrain syllable boundaries; prefix choices retain the exact unconsumed source spelling. SI deliberately lowers the extra single-character cost to let dictionary frequency compete more strongly with segmentation structure. The residual cost discourages excessive character splitting. This differs from the upstream scoring formula and does not establish MSIME-equivalent quality.

Existing English word lookup and continuous English segmentation remain an independent lane. Chinese/English lexical mixing is intentionally deferred during this refactor. The exact original input remains an explicit candidate, including unknown input and configurations with all languages disabled.

When the leading candidate is a constructed sentence, the input window offers its first two whole choices, then exact first-word candidates and single-character alternatives. Later pages continue word/character selection rather than filling with more sentence completions. For `biruzhege`, choose `比如` to consume only `biru`, then choose `这个` from the remaining `zhege`. First-word choices must be single lexical entries or saved personal units; constructed fragments and abbreviated spellings are not treated as first words. Single-word lookup and English completion keep the ordinary ranked alternatives. The input window shows at most 27 candidates (three expanded pages), preserving a complete candidate for each matching language identity before prefix-only fallbacks and the exact original input; these protected alternatives may add a whole candidate beyond the first two. Lower-ranked choices remain available in the engine and Settings preview. Prefix choices show a small arrow in the single line; the expanded list omits consumed-length labels. Tooltips and accessibility descriptions retain the exact source characters consumed. Return commits exact remaining spelling. Provisional hints can change when full results arrive. Candidate-only refreshes preserve unchanged host composition text and visible row views. Live host flicker and compatibility remain unverified. This organization supports sequential selection; it does not judge sentence meaning.

All input processing is local. SI has no analytics, keystroke logging, or cloud dependency for typing. Optional, user-initiated software update checks contact SI's download service without sending input or personal phrases. Language and learning settings are saved in UserDefaults. Personal learning is off by default; when explicitly enabled it retains aggregate input-to-candidate preferences on this Mac. See [personalization and privacy](docs/PRIVACY.md) for retained fields, expiry, pause, deletion, and storage limitations.

## Vocabulary maintenance

Chinese data is now maintained under [Data/Chinese/MSIME](Data/Chinese/MSIME/README.md): pinned MSIME source snapshots, provenance, reading corrections and an SI-owned additions/exclusions overlay generate one read-only SQLite dictionary used by both the package and app. Word-context tables are pinned separately. All resource downloads are explicit maintainer actions; typing never downloads data. The algorithm is Swift, with no Rust dependency.

```sh
python3 scripts/msime_dictionary.py build
python3 scripts/msime_dictionary.py build --check
python3 scripts/msime_dictionary.py fetch-context
```

The Chinese dictionary currently contains 953,710 unique text/reading entries. Its coverage, new ranking and optional-learning interactions remain unverified. The former Chinese Swift tables, direct Rime imports and their maintenance pipeline have been removed. English vocabulary, wordfreq data and functionality are temporarily retained; see [English maintenance](docs/ENGLISH_VOCABULARY.md). Public corrections and additions belong in `Data/Chinese/MSIME/si-entries.json`; private personal phrases and learning archives are preserved. [The implementation plan](docs/IMPLEMENTATION_PLAN.md) tracks unfinished correction, optional neural reranking and parity work.

## Automatic prefix confirmation

Enable **Automatically confirm stable prefixes** in **SI Settings → Typing** to let SI confirm leading Chinese words while you continue typing or pause. It is off by default. SI keeps at least four output characters editable during continuous typing, or two after a pause of at least 1.8 seconds; complete-word boundaries can leave a longer ending. Only the confirmed source spelling is consumed, and the remaining exact spelling stays marked and editable without an extra space.

Automatic confirmation requires matching source/output boundaries across nearby full-search alternatives. Continued typing must also preserve the prefix across multiple results with additional input. A pause relaxes the ending length, but requires a prefix of at least two characters and does not override disagreement between candidates. Ambiguous input can remain entirely editable. Provisional hints never trigger confirmation. English/mixed leaders, uppercase/code-like spelling, personal phrases and unrecognized spans are excluded. These are conservative local heuristics, not a guarantee of sentence meaning or a way to predict whether later typing will turn a spelling into an identifier.

Editing, moving the caret, navigating/expanding candidates, or crossing a host boundary cancels automatic confirmation; fresh typing at the composition end starts new evidence. Settings changes, secure input, cancellation and stale asynchronous results cannot authorize a pending confirmation. Each pause can confirm at most once until more input arrives. Automatic confirmation does not train personal learning or become previous-word context, and saves no typing history. Return and shortcuts preserve only the remaining spelling once a prefix has been committed; editing already committed text uses the host application's normal editing tools. Native timer/focus behavior still requires the checks in [testing](docs/TESTING.md#automatic-prefix-confirmation).

## Personal learning

Open **SI Settings → Personalization** and enable **Personal learning**. Repeatedly choosing a candidate raises its position for that spelling. Only deliberate selections train learning: number keys, mouse selection, or navigation followed by Space. Simply accepting the default with Space does not create or reinforce a preference; recent preferences matter more, with a 14-day half-life and a bounded ranking bonus. Other enabled languages and the original input remain available.

Chinese single-character preferences apply only when ranking candidates for their own spelling, including an explicitly consumed prefix; they do not transfer into other compositions. Chinese words with two or more characters and English word choices can still influence matching tokens inside longer compositions: learning `shike` → `食客` can raise `我食客` for `woshike`. Search keeps both a base-score beam and a personalized beam. Token preferences are averaged by the amount of input they cover and share the 32-point frequency cap with whole-input preferences; they are not added twice. This reuses existing aggregate records and does not split confirmed sentences into newly saved words. Personal/verbatim paths receive no learning bonus. Previous-word pairs still rerank generated candidates rather than internal tokens.

English-only composition retains its lexical-boundary safeguard against split-word token preferences. Chinese/English lexical integration remains deferred. The Chinese decoder uses only Chinese lexical and explicitly saved personal nodes; the existing code/English safeguards for punctuation and automatic confirmation remain separate from sentence ranking.

Whole-input and previous-word preferences apply before complete/prefix presentation limits. Prefix choices use only their consumed spelling. This lets saved choices influence the bounded shortlist before it is shown, while preserving base-ranked complete alternatives. Paths lost at an earlier search position can still be absent; this is bounded decoding rather than exhaustive sentence search.

Turning learning off pauses both updates and personalized ranking. **Manage Saved Preferences…** supports searching and forgetting individual entries; **Clear Saved Data…** removes all learned preferences. Existing records are preserved; earlier versions did not distinguish default acceptance from deliberate selection in saved data, so unwanted old preferences may need individual deletion. Entries expire after 90 days without use, with a maximum of 5,000 entries. Secure event input suppresses learning and personalized ranking. Literal commits, cancellation, focus changes, and shortcut passthrough are not learned. Candidate preview reflects preferences but never trains on preview text.

**Learn from the previous chosen word** is a separate, initially disabled option. It adds aggregate word-pair preferences, using only the previous confirmed candidate from the current typing session for up to five minutes. Cancellation, focus callbacks, host navigation, consent changes, and clearing reset this session context. No surrounding document text is read. Word pairs share the same 5,000-entry limit and 90-day expiry; the manager shows and searches their previous word. Preview uses frequency ranking without a preceding-word context.

Preferences are stored in a private local directory using atomic replacement. Writes are asynchronous and coalesced for 300 ms; normal termination flushes pending changes. A crash or forced termination can lose recent unsaved learning. Read/write failures appear in Settings; corrupt data is preserved until explicitly cleared. There is no cloud synchronization, full-text history, automatic phrase harvesting, or neural-model training.

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
| Left / Right | Page through expanded candidates; move the composition caret by a whole character when collapsed |
| Home / End | Move to the start/end of the composition |
| Up / Down, Page Up / Page Down | Navigate SI's candidate window |
| 1–9 | Select candidates on the current numbered page |
| Delete / Forward Delete | Remove the previous/next composition character at the caret |
| Escape | Cancel the composition |
| Punctuation / symbols | Stay editable in the composition by default; optional punctuation confirmation is configurable |
| Tab | Apply the configured composition-boundary behavior |
| A shortcut | Commit original spelling and pass the event through |

Outside composition, control keys and punctuation pass through. Shift and Caps Lock do not switch language modes. With both languages disabled, SI only offers the original text. SI's nonactivating AppKit candidate panel starts as a horizontal single line with up to five numbered choices. Short candidates such as `a` remain visible beside their numbers. Click the chevron to expand to a vertical list of up to nine choices per page, or collapse again. Expansion keeps the current selection and lasts until the composition ends; the next composition starts collapsed. The same shortlist is used in both layouts: at most six compact pages or three expanded pages, including each matching language identity and the exact original input.

Number shortcuts select the currently visible candidates (1–5 in the single line, 1–9 when expanded), including after paging. Up/Down changes the highlighted choice, Page Up/Page Down moves by the current layout's page size, and Space confirms the highlighted candidate. When expanded, Left/Right also moves to the previous/next page using the same selection behavior as Page Up/Page Down; previous/next buttons remain available. Mouse-wheel and trackpad scrolling do not change pages or selection. Collapse the list to edit the composition caret with Left/Right; Home/End remain available in either layout.

Ordinary typing updates marked spelling before searching candidates off the main thread. A separate bounded search supplies provisional hints for the latest spelling while the full search runs, so an obsolete full search does not hold up every update. Both stages use the same decoder and maintain one running request plus one latest replacement per client. Provisional hints have narrower lexical coverage and may change when full results arrive; they do not replace the final candidate set. Only matching composition revisions may update the window. Pending hints refresh the rows without hiding the panel or shrinking its current size; mouse, page and expansion controls remain disabled until full results arrive. Space, digits, candidate navigation, and optional punctuation confirmation resolve full current candidates before selecting; these confirmation boundaries can still wait for a search. Return, Escape, and shortcuts preserve/cancel spelling without waiting.

The candidate window uses a slim warm-neutral strip, a soft peach selection pill and an orange selected number. Text remains dark in the light appearance, with a coordinated dark palette. Candidate buttons keep numbers close to their text and fit their content rather than stretching across unused space. Small arrow, pin and text symbols distinguish prefix, personal and typed-text sources in the single line; expanded rows show descriptive hints. Full language/source details remain in tooltips and accessibility labels. The system Increased Contrast preference adds a stronger outline; page controls appear only when more than one page is available.

The panel anchors below the beginning of the marked composition, using InputMethodKit's inline-session coordinates, and moves above it when space is limited. Document-range coordinates are a fallback only after checking the returned range. A temporary geometry failure can reuse the last valid position in that composition; fresh inline coordinates replace earlier fallbacks, and without reliable geometry the panel stays hidden. Host-specific positioning still requires manual verification.

**Typing → Punctuation during composition** defaults to **Keep Composing**: punctuation and symbols stay in the marked spelling so `example.com`, `user@example.com`, `foo/bar`, and `nihao,world` can be typed and edited as one composition. ASCII period `.` stays editable under every policy, even after candidate navigation; it never confirms a candidate or becomes `。`. Non-confirming symbols also remain editable in the optional policies. Return commits the exact spelling; Space/numbers/mouse still confirm the current candidate, and Escape cancels the entire composition. Apostrophes retain their Pinyin boundary meaning. Digits remain candidate shortcuts rather than general numeric entry. Tab commits literal spelling and passes through in Keep Composing. **Smart Chinese Punctuation** and **Confirm Candidate** remain optional confirmation policies; saved explicit choices are preserved. They confirm supported punctuation/Tab with existing English, prefix and personal-code safeguards; smart mode converts `,;:!?()[]` after Chinese endings. Symbols outside composition pass through, and shortcuts preserve the exact spelling. Symbol insertion does not train learning; optional delimiter confirmations do not train either. Quotes are not automatically paired.

## Project layout

```text
mac/SI/App/             App lifecycle and InputMethodKit server
mac/SI/InputMethod/     Client events, marked text, selection state, and AppKit candidate window
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

The static landing page supports English and Simplified Chinese, with an accessible scripted input demonstration. Its download buttons use the published R2 image and provide the matching checksum and source archive. Build it with `node scripts/build-website.mjs`; see [website development and GitHub Pages deployment](docs/WEBSITE.md) for preview, localization, download updates, and custom-domain setup.

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) and the [architecture](docs/ARCHITECTURE.md). Keep code, UI copy, documentation, issue reports, and pull requests in English. Language data and user input naturally retain their original scripts.

See the [roadmap](docs/ROADMAP.md) for planned work and [manual verification](docs/TESTING.md) for host-app checks. GitHub Actions builds the macOS app and runs core tests on pushes and pull requests.

The existing `./scripts/benchmark.sh` harness covers eighteen synthetic scenarios with saved preferences and personal phrases, English lookup, and synchronous/deferred edit costs. It has not been run for the Chinese migration; initialization is now lazy on candidate workers and old initialization/timing figures do not apply. Benchmark scenarios and quality fixtures still need reconciliation with the new policy. See [dictionary provenance and decoder limits](docs/DICTIONARIES.md), [the MSIME algorithm study](docs/MSIME_ALGORITHM.md), and [verification status](docs/VERIFICATION.md).

## License

SI is licensed under the GNU General Public License, version 3. See [LICENSE](LICENSE). The repository's existing license is preserved. The vocabularies include SCOWL, MIT-licensed CSpell lists and selected Rime Ice data; wordfreq-derived frequency data retains CC-BY-SA-4.0 attribution and redistribution terms. See [data provenance](docs/DICTIONARIES.md). Additional dictionaries or language models must have compatible licenses and documented provenance.
