# SI

**One input. Every language.**

SI is an open-source macOS input method built around one idea: choose the languages you use in Settings or SI's input menu, then type without switching between language modes. Candidates from enabled languages appear together, including ambiguous matches. The original text always remains available.

> **Status: development preview.** macOS conversion uses the Rust SI engine through a native bridge. Live host compatibility and ranking quality still need verification.

The English dictionary includes the article `a` for exact lookup and continuous word segmentation, such as `sendaenglish` → `send a english`. Existing ranking and candidate-window limits still apply; see [common English additions](docs/ENGLISH_VOCABULARY.md#common-english-additions).

## How it works

Enable **English** and **Chinese (Simplified)** once. SI queries both providers for each composition:

| Input | Example candidates |
| --- | --- |
| `shi` | `是`, `时`, `事`, `十`, `ship`, `shirt`, `shi` (as typed) |
| `he` | `he`, `和`, `喝`, `河`, `hello`, `help`, `her`, `he` (as typed) |
| `nihao` | `你好`, `nihao` (as typed) |
| `iwanttobuild` | `I want to build`, `iwanttobuild` (as typed) |
| `woxiangyaodeploy` | `我想要 deploy`, `woxiangyaodeploy` (as typed) |

The Rust engine searches a bounded word lattice over full Pinyin and English
spelling, including mixed paths and final-word completion. Apostrophes
constrain Pinyin syllable boundaries. Prefix choices consume the exact
original spelling, including umlaut aliases and trailing separators. The
engine scores paths using dictionary counts, optional paired word grams,
and spelling and language-transition costs. Complete candidates precede
prefixes. Prefixes sort by decreasing consumed length, then by score within
the same range. The exact original input stays available for every nonempty
composition. [Rust conversion architecture](docs/ARCHITECTURE.md#rust-conversion)

In compatible macOS text fields, SI passes the full text before the composition
to the local Rust engine. The engine uses word grams from the last preceding
sentence to help rank the first word of each candidate. This context stays in
memory. If the host cannot provide the text, conversion uses the composition
and local resources as usual.

The window uses one 27-choice ordinary shortlist, including the exact original input, and additionally retains every generated Chinese dictionary character that the system font can display. Only the first four ranked choices may include constructed sentences or multiword fragments. Remaining ordinary slots are single-character/word choices, including exact prefixes, so sentence alternatives cannot fill later pages. Chinese, English and mixed hypotheses share the same four-choice eligibility without language reservations. Before shortlisting, the window excludes nonliteral candidates containing missing glyphs, including system LastResort placeholders; supported rare characters remain pageable. All retained nonliteral choices keep engine order, without language reservations, and the exact original input stays last. Prefix choices show a small arrow and consume only their exact source spelling: choosing `比如` from `biruzhege` leaves `zhege` editable. With `sheguofennudehai`, generated character choices remain pageable, allowing `涉` → `过` → `愤怒` → `的` → `海` to be selected individually. Tooltips and accessibility descriptions retain the exact consumed spelling. Return commits exact remaining spelling. Provisional hints may change when full results arrive. Live host compatibility remains unverified.

For `cichuxiande`, the single-character prefix `词` has the same lexical score as standalone `ci`, regardless of how `chuxiande` could convert. Choosing `词` leaves that exact remainder editable; the intended full sentence is not guaranteed as the first choice.

Ordinary conversion runs locally. SI has no analytics, raw-keystroke logging, or cloud dependency for ordinary typing. Optional, user-initiated software update checks contact SI's download service without sending input or personal phrases. Language and learning settings are saved in UserDefaults. Personal Learning, Sentence Learning and Input History are independently off by default. Personal Learning retains aggregate candidate preferences. Sentence Learning builds a local language model. Input History can retain each submitted spelling and text pair permanently on this Mac. Separately enabled AI completion can send composition and app context to a selected provider. See [personalization and privacy](docs/PRIVACY.md) for retained fields, retention, pause, deletion, and storage limitations.

Debug and Release bundle `target/si-data/main.silex` and
`target/si-data/words.sigram`. Xcode checks that the snapshots are
compatible before including them in `SI.app`.

## Input languages

The macOS input-source menu for SI includes independent **English** and **Chinese (Simplified)** checkmarks. Click either to enable or disable that input language without opening Settings. These global preferences stay synchronized with Settings and allow both languages together or neither (exact original input remains available). Changing a checkmark refreshes the active composition without committing its spelling or moving its caret. No keyboard shortcut is assigned. Per-application direct input still takes precedence; to convert Chinese in an app such as Terminal, first turn off its direct-input rule in Settings.

## SI Settings

Open **SI Settings…** from the input menu. **Typing** opens first, with language and composition controls. **AI Completion** is a separate page under **Input**. Use the sidebar or search for a setting such as “punctuation”, “export” or “screen recording”. **Personal Data** groups Personal Phrases, Personal Learning, Sentence Learning and Input History into separate pages. Experimental permissions and software updates are under **System**.

## Interface language

The app supports English and Simplified Chinese. Settings, input-menu actions, candidate descriptions and accessibility labels follow the macOS preferred app language, with English as the fallback. Set a preferred language for SI in **System Settings → General → Language & Region → Applications**, where available, then restart SI normally for the change to take effect. Do not launch a second copy of the input method.

Interface language is independent of the English/Chinese input-language switches. Changing it does not change candidates, committed text, personal phrases, learning consent or saved data. The compact E/C/A punctuation badges retain their existing identifiers; their full descriptions are localized.

## Vocabulary maintenance

Edit the `text,reading,weight` CSVs in [Data/Chinese](Data/Chinese/) and
[Data/English](Data/English/). The `weight` field is an explicit nonnegative
integer count. Every flat category CSV is compiled; identical exact
text/reading pairs sum their counts across rows and files. Different readings,
case variants and byte-distinct outputs remain separate.

The Rust resource tools compile and update the snapshots that Xcode packages.
The packaged source notices and licenses are under
`mac/SI/Core/Resources/`. Use `./scripts/si-lexicon-build.sh` to build
a standalone Rust dictionary, or pass a new output path as its argument.
After editing either language's CSVs, run `./scripts/si-lexicon-import.sh`
to update the existing `target/si-data/main.silex`. Matching entries take
their current CSV totals, new entries receive new IDs, and existing entries
absent from the CSVs stay in the lexicon.
To remove entries, build a fresh lexicon at a new path and regenerate its
paired word grams from the selected corpus before using them in the app.

## Automatic prefix confirmation

Enable **Automatically confirm stable prefixes** in **SI Settings → Typing** to let SI confirm leading Chinese words while you continue typing or pause. It is off by default. SI keeps at least four output characters editable during continuous typing, or two after a pause of at least 1.8 seconds; complete-word boundaries can leave a longer ending. Only the confirmed source spelling is consumed, and the remaining exact spelling stays marked and editable without an extra space.

Automatic confirmation requires matching source/output boundaries across nearby full-search alternatives. Continued typing must also preserve the prefix across multiple results with additional input. A pause relaxes the ending length, but requires a prefix of at least two characters and does not override disagreement between candidates. Ambiguous input can remain entirely editable. Provisional hints never trigger confirmation. English/mixed leaders, uppercase/code-like spelling, personal phrases and unrecognized spans are excluded. These are conservative local heuristics, not a guarantee of sentence meaning or a way to predict whether later typing will turn a spelling into an identifier.

Editing, moving the caret, navigating/expanding candidates, or crossing a host boundary cancels automatic confirmation; fresh typing at the composition end starts new evidence. Settings changes, secure input, cancellation and stale asynchronous results cannot authorize a pending confirmation. Each pause can confirm at most once until more input arrives. Automatic confirmation does not train Personal Learning. If separately enabled, Input History records its submitted prefix like other SI commits. Return and shortcuts preserve only the remaining spelling once a prefix has been committed; editing already committed text uses the host application's normal editing tools. Native timer/focus behavior still requires the checks in [testing](docs/TESTING.md#automatic-prefix-confirmation).

## Direct input by application

Open **SI Settings → Direct Input → Manage Direct Input…** and turn on direct input for apps such as Terminal. Every app uses normal SI conversion by default. The searchable list discovers apps in the standard system, local and user Applications folders, plus running apps, and displays each app's system icon beside its name. **Add Application…** lets you select an `.app` stored elsewhere; **Refresh** rescans the list. Rules are saved locally by bundle identifier, and enabled rules remain listed with a generic application icon when an app is no longer installed.

While SI is selected, press **Control + Shift + I** to toggle Direct Input for the current IMK client application, including turning conversion back on. The same app rule is saved and synchronized with Settings. Change the shortcut with **Direct Input → Record Shortcut…**, or restore the default with **Reset Shortcut**. Shortcuts use a physical key and exact Control/Option/Shift/Command modifiers; Caps Lock does not affect matching. Hold-to-repeat toggles only once. No global keyboard monitor or additional permission is used; system or host-reserved shortcuts may take precedence.

In a selected app, SI passes key events to the host without composition, candidates, punctuation conversion or automatic spacing. Space, Tab, Return, navigation and shortcuts belong to the host. If the rule takes effect during composition, SI inserts only the exact pending spelling once and rejects old candidate results and automatic-confirmation tasks. SI does not learn vocabulary while direct input is enabled; existing saved data remains until deleted. Turning direct input off restores ordinary conversion and the app's independently configured learning consent.

Rules use the InputMethodKit client's application identity, not the foreground process. A browser rule applies to every tab and input field; an editor rule includes its embedded terminal. It cannot distinguish an address from a search in a combined address bar. Application-wide rules need no Accessibility or Input Monitoring permission, and SI remains the selected system input source. Native host behavior still requires the [direct-input manual checks](docs/TESTING.md#direct-input-by-application).

## AI completion

Open **SI Settings → AI Completion**. Select **Codex CLI**, **Claude Code**, or **OpenAI API**. Sign in to the installed CLI first or save your OpenAI API key in SI, which stores it in macOS Keychain. The page displays the resolved executable path. Click **Edit** to enter an absolute path, including paths beginning with `~/`, or choose **Use Automatic Discovery** to restore automatic lookup. Automatic discovery checks the SI process PATH first, common installation directories next, and NVM Node versions when needed. Grant Screen Recording in macOS, then enable **AI Completion**. It works in all apps where SI conversion is active. Existing automatic AX consent does not enable the screenshot feature; re-enable it after upgrading.

While composing, press **Tab** to request a prediction. SI sends the exact spelling, a whole candidate, verified IMK field text within 1,024 UTF-16 units on each side when available, and a screenshot of the current input window. After a result appears, press **Tab** again or click the AI row to insert it. Additional Tab presses while a request is running wait for that request. Ordinary typing never requests predictions. Tab outside composition and with AI disabled follows normal routing.

All three backends receive the image as an attachment and retain the 30-second prediction timeout. Edits, candidate selection and app/window changes invalidate suggestions. Settings shows the latest status. See [privacy](docs/PRIVACY.md#ai-completion) and [host verification](docs/TESTING.md#ai-completion).

Codex CLI and Claude Code receive SI's `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY` and `NO_PROXY` environment variables, including lowercase forms, plus custom certificate environment variables. For GUI launches without these variables, SI supplies enabled macOS static HTTP, HTTPS and SOCKS proxies as a fallback. Explicit environment values take priority, including empty values. SI does not load shell startup files; a proxy exported only in `.zshrc` is not automatically available to the input method. PAC/WPAD automatic proxy discovery is not evaluated for CLI requests. The OpenAI API backend uses URLSession's system proxy handling. See [CLI environment details](docs/ARCHITECTURE.md#ai-completion).

## Experimental permissions

**SI Settings → Permissions** shows the current status for Accessibility and Screen Recording. Click **Open Settings…** on the row for the permission you want to grant. Each button opens its Privacy & Security pane and shows a floating panel. Drag SI from the panel into the system list, then enable the permission. You can also click **+** in the system list, press **Shift-Command-G**, go to `~/Library/Input Methods/` and select the installed `SI.app`. After granting permission, refresh the status in SI Settings. If macOS asks for a restart, restart the installed SI.

Screen Recording is used for independently enabled, manually triggered AI completion. Granting system permission by itself leaves ordinary conversion, enabled languages, Personal Learning and Input History unchanged. Accessibility remains an independent experimental permission action. Input Monitoring and global event taps are not used. Native permission dialogs still require [manual verification](docs/TESTING.md#experimental-permissions).

Xcode resolves [PermissionFlow 2.11.4](https://github.com/jaywcjlove/PermissionFlow/releases/tag/v2.11.4) on the first app build. Its MIT license permits redistribution with the [included notice](mac/SI/Resources/PermissionFlow-LICENSE.txt).

## Personal Learning

Open **SI Settings → Personal Learning** and enable **Enable Personal Learning**. It is off by default. All eligible apps share one vocabulary and aggregate usage/correction counts. A deliberate selection of a nonfirst candidate makes it the first ordinary choice the next time the entire normalized source spelling matches. A later deliberate choice replaces that preference, including across languages. Explicit personal-phrase pins retain priority; other candidates and exact original input remain available. Case and ü/v/u: aliases use existing normalization, while explicit apostrophe boundaries remain distinct. Shorter spellings and longer compositions do not inherit this forced placement. Prefix confirmation records only consumed spelling, never the pending remainder.

When you manually select successive prefixes from one unchanged composition, SI also learns the completed combination after every part has been successfully submitted. For example, selecting `锁` then `成` from `suocheng` retains the individual `suo`/`cheng` entries and adds `suocheng` → `锁成`. Any nonfirst correction in the sequence makes the whole spelling a remembered choice; a sequence of only first choices remains usage-only. Editing the remaining spelling, cancellation, focus/configuration/consent changes, failed insertion, or an excluded fragment interrupts aggregation. Only confirmed fragments are retained transiently in the current client session, within the existing learning size limits. Input History still records the actual separate submissions and receives no synthetic combined row.

For candidate-choice learning, accepting the displayed first candidate by Space, number or mouse only updates usage; it does not increase ranking strength or change the remembered choice. Every three deliberate nonfirst selections also add one frequency-ranking point, up to 32, for whole/prefix and eligible internal-token ranking. This gradual bonus is separate from immediate exact-match placement. Neither strength nor records decay or expire with age. At most 5,000 entries are kept; capacity eviction removes the least recently used entries with deterministic identity ties. Candidate-choice learning retains the selected output as one entry. Literal, personal/verbatim, punctuation, delimiter and automatic-confirmation commits do not train vocabulary. Existing spelling/output size limits remain 128/512 bytes.

**Manage Learning Data…** supports global search and Forget for candidate-choice preferences. **Clear Personal Learning Data…** removes candidate-choice preferences. Forgetting the remembered choice removes its forced placement. Personal Learning has one global switch, with no per-app pause, filter, deletion or clear controls. Turning learning off, secure input and the separate direct-input rules suppress learned ranking and saved suggestions. Candidate-choice learning uses SI submissions.

The existing `SI/Personalization/application-memory-v1.json` path now uses vocabulary-only schema 4. On successful load, schemas 1–3 migrate atomically into one global vocabulary, dropping app identity and retired history. Identical spelling/language/output records combine bounded usage/correction counts, retain the latest usage/base metadata and use the maximum stored strength rather than adding strengths. Schema-1/2 ambiguous strengths/corrections are reset; schema-3 evidence is retained. Old archives have no deliberate-selection timestamp, so migration does not guess an immediate first choice. Retained old records are not discarded because of age; previously deleted/expired records cannot be recovered. Corrupt or unsupported archives remain untouched with a visible error, and failed migration writes pause loading. Existing learning consent is preserved. The retired per-app exclusion key is removed and no longer scopes learning.

The former App History completion/draft feature and previous-word pair learning remain removed. The new Input History below has separate consent and storage. The separate retired `SI/Personalization/preferences-v1.json` archive is never loaded, imported or used as a fallback; its old consent flags are ignored. **Delete Old Shared Learning Data…** still explicitly deletes that inactive archive and its consent flags without changing current vocabulary or personal phrases. External backups remain outside SI's deletion controls. Native host, Settings keyboard and VoiceOver verification remain separate [manual checks](docs/TESTING.md#app-vocabulary).

### Sentence learning

In **SI Settings → Personal Data → Sentence Learning**, **Learn from Submitted Sentences** controls the Return-time read. It is independently off by default. If you explicitly enabled Sentence Learning and it was active before upgrading, your choice carries over. When there is no pending composition, a plain Return lets SI learn from the entire text exposed by the active input client, including text after the caret, multiple lines and existing or pasted content. In an editor, the client may expose the entire document. No prior SI submission is required. Return continues to the host. Secure and direct input are excluded.

SI batches the text in memory and reuses the Rust ingestion and word discovery behind `si-cli user ingest` and `si-cli user learn`. Derived vocabulary and word grams can influence subsequent candidates. The profile stays on this Mac. SI discards the captured text after processing it. The **Sentence Learning** page reports skipped reads, queued text and saved models. **Clear Sentence Learning Data…** clears the sentence model and pending samples. Older Sentence History records can be explicitly removed with **Delete Old Sentence History…**. See [sentence learning privacy and retention](docs/PRIVACY.md#sentence-learning) and [native checks](docs/TESTING.md#sentence-learning).

## Input History

Open **SI Settings → Input History** and enable **Save Input History**. It is independently off by default; enabling Personal Learning or a language does not enable history. Each successful SI composition submission keeps the exact consumed spelling, submitted text, timestamp, language/mixed identity and commit reason. Examples include `nihao` → `你好`, English conversion and original English/code committed with Return. SI-inserted spaces/punctuation are retained in the submitted output. Repeated submissions remain separate rows. Prefix selection and automatic confirmation each save only their submitted portion, leaving the pending remainder unrecorded until it is committed.

**History has no automatic expiry or record-count limit.** It stays on this Mac until you explicitly delete it. The 5,000-entry Personal Learning cap does not apply. History does not affect ranking, create completions or enter model training automatically. **View Input History…** offers spelling/text search and newest-first pages of up to 100 records, with individual Delete and **Clear Input History…**. Clearing learning/phrases/history affects only the chosen data category. Disabling history stops new recording while keeping saved records; accepted pending writes still finish.

History includes literal, personal-phrase, punctuation and automatic SI submissions when enabled. It does not capture cancelled compositions, raw keystrokes, document/clipboard text, standalone keys passed to the host outside composition or text in direct-input apps. Secure event input suppresses recording; it cannot detect every sensitive field. Recording is checked before and after the host insertion call, including consent generation changes during reentrant callbacks. Data is prospective: past input and retired history archives are not imported.

**Export Input History…** saves all persisted history as one versioned JSONL file, including records hidden by search. The action opens a save panel directly, with no backup/training distinction or purpose flag. Export never uploads or sends a file. It contains private source/output text and timestamps, and deleting local history does not delete exported copies. Accepted writes finish before export; pending save failures must be resolved first.

The receiver can run `python3 scripts/input_history.py inspect FILE.jsonl`, `restore FILE.jsonl --output NEW.sqlite3`, or `prepare FILE.jsonl --output NEW_DIRECTORY`. Restore validates versions/count/checksum and recreates every event exactly. Training preparation accepts the same export and produces an unsplit candidate CSV plus provenance for review, without modifying existing data or starting training. See [export/restore and training-observation workflow](docs/INPUT_HISTORY_EXPORT.md).

For text-only copies of Input History or earlier Sentence History exports, run `python3 scripts/input_history_to_txt.py`. It converts the JSONL files in `corpus/chinese/raw/input-history/` to adjacent same-name `.txt` files containing only submitted text (`output`), in original order with repeats preserved. You can also pass a file or directory; existing TXT files require `--overwrite`. See [plain-text extraction](docs/INPUT_HISTORY_EXPORT.md#plain-text-extraction).

The independent owner-only SQLite database is `~/Library/Application Support/SI/InputHistory/history-v1.sqlite3`. It is not encrypted; private text can be accessible to other software running as you, administrators and backups. I/O stays off the main actor/key-event path. Writes are serialized and transactional, retries do not duplicate a submission, and clear cannot be undone by older pending writes. Open/save failures visibly pause recording; failed writes remain in memory for **Retry Saving History**, and corrupt/unsupported files remain untouched until explicit clear. Normal termination waits for queued writes; forced termination, disk failure or quitting without retry can lose unsaved entries. External backups remain outside SI's deletion controls. See [privacy](docs/PRIVACY.md#input-history) and [manual checks](docs/TESTING.md#input-history).

## Personal phrases

Open **SI Settings → Personal Phrases → Manage Personal Phrases…** to add a code such as `xm` and the exact text to insert. Choose its candidate language and optionally prefer it for a full-code match. Phrases work even with learning off, respect enabled languages, and remain until manually deleted. They are not copied into learning records or used as preceding-word context.

The manager supports search, editing, deletion, clear, and additive JSON import/export, with at most 1,000 phrases. Imports preserve existing phrases and pin settings; invalid or over-capacity imports leave the dictionary unchanged. Saved codes also participate in longer Pinyin/mixed paths: saving `xm` → `小明` lets `woaixm` offer `我爱小明`. Any path containing a personal phrase stays excluded from automatic learning and previous-word context. Exported files contain phrase text and must be handled as personal data. See [phrase format and controls](docs/USER_PHRASES.md).

## Requirements

- macOS 14 or later.
- Xcode 26 or later with Swift 6.2 or later and the macOS SDK.
- Rust 1.89 or later with the `aarch64-apple-darwin` and `x86_64-apple-darwin` targets for a universal app.
- Git LFS for the maintained training CSVs. On macOS, install it with `brew install git-lfs` and run `git lfs install` before cloning.
- Xcode resolves the pinned Sparkle 2.10.0 update framework on the first app build. Unsigned development builds require no Apple Developer account.

## Get started

```sh
git clone https://github.com/caterm-dev/si.git
cd si
git lfs pull
./scripts/test.sh
```

Place the prepared `main.silex` and matching `words.sigram` in
`target/si-data/`, then run `./scripts/build.sh`. The application is built
at `.build/xcode/Build/Products/Debug/SI.app`. See the
[resource preparation commands](#rust-engine-workspace).

Training CSVs under `llm/pinyin_to_text/data/csv/` are stored with Git LFS. For an existing clone, install Git LFS, run `git lfs install --local`, then `git lfs pull` to download the CSV contents. See [the data guide](llm/pinyin_to_text/data/csv/README.md) before preparing a dataset.
The build compiles the Rust bridge. The test script builds a separate fixture
dictionary from the tracked CSVs. Generated snapshots and history databases
stay outside Git.

To work in Xcode, open `mac/SI.xcodeproj` and choose the shared **SI** scheme. The Run action passes `--settings` to show the settings window. Core tests are run through Swift Package Manager using `./scripts/test.sh`; they are not an Xcode test target.

The Xcode project defaults to ad hoc signing for local development. No personal signing team is committed to the project. For distribution, configure your own signing identity and team. The command-line build disables code signing. Local installation requires a valid Developer ID Application certificate and its private key in Keychain; the installer signs the staged copy with that identity.

## Install for local development

```sh
./scripts/install.sh
```

This builds the optimized **Release** app, stages and verifies a Developer ID Application signed copy, and replaces `~/Library/Input Methods/SI.app` without retaining an app backup. The previous bundle is held only in temporary staging for rollback if replacement fails, then removed on success. Use `./scripts/install.sh Debug` only when debugging an installed input method; Debug disables compiler optimization and is not representative of typing performance. The installer then asks macOS to register the bundle and verifies exactly one selectable SI keyboard input source. It does not enable or select SI and never requires `sudo`. Stop any Xcode run first; if the installed SI process is running, select another input source and log out before replacing it.

The installer automatically selects a unique valid Developer ID Application identity from Keychain. If multiple identities are available, set `SI_SIGN_IDENTITY` to the same certificate name used for release (or its exact SHA-1 fingerprint):

```sh
SI_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID1234)' ./scripts/install.sh
```

Missing, invalid or ambiguous identities stop installation before building or replacing the app; there is no ad hoc fallback. The same setting applies to `reinstall.sh`. Local installation does not require an Installer certificate, notarization or a timestamp-server request. Keep the signing identity and bundle identifier consistent between local and release installs. Switching from an ad hoc or Apple Development build can require granting Accessibility/Screen Recording again; actual grant retention across updates requires a manual check.

To automatically stop SI and reinstall during development, run:

```sh
./scripts/reinstall.sh          # Release (default)
./scripts/reinstall.sh Debug
```

This stops processes named exactly `SI` owned by the current user, waits up to five seconds, and uses SIGKILL if necessary before calling the existing installer. Pending composition or unsaved learning may be lost. The installer's running-process checks, signing, temporary rollback, and registration remain in effect. Select another input source and stop any Xcode run first to avoid SI restarting during the build; if it restarts, installation aborts rather than replacing a running app. The script does not change enabled or selected input sources or force logout.

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

The corrected bundle/input-source identifier is `com.caterm.inputmethod.si`. The installer can replace the earlier `com.caterm.si` preview without retaining an app backup. Language, punctuation, and learning-consent settings continue using the original `com.caterm.si` preferences domain; personal phrases and learning archives keep their existing locations. If an earlier SI source was manually added, remove its stale entry in Keyboard settings and add the corrected SI source.

To uninstall, select another input source, remove SI in Keyboard settings, then move `~/Library/Input Methods/SI.app` to Trash and log out. Older installer backups, if present in `~/Library/Application Support/SI/Backups/`, can be deleted manually; new installations do not create them.

## Check for updates

In the installed Release app, choose **Check for Updates…** from the SI input menu or **SI Settings → About SI → Software Updates**. SI uses Sparkle, as Caterm does, with a separate SI update feed. Checking is manual; background checks, automatic installation and system-profile submission are disabled. Sparkle verifies the update signature and asks before downloading/installing. Save your work and finish composing before installing; SI restarts and flushes pending personal-data writes through its normal termination path. If typing does not resume, log out and back in. Debug builds and copies outside `~/Library/Input Methods/SI.app` show an explanation in Settings and disable checking.

Versions without the updater need one manual installation of an updater-enabled release. A check requires a published SI Sparkle feed; adding this implementation does not publish a release or establish native update/host compatibility. See [release and update configuration](docs/RELEASING.md#in-app-updates).

## Package and publish a DMG

```sh
./scripts/package-dmg.sh --dry-run   # Inspect Universal Release packaging
./scripts/package-dmg.sh             # Local ad hoc signed preview
./scripts/release.sh --dry-run       # Detect signing identities and inspect publication
./scripts/release.sh                 # Increment patch/build, commit versions, notarize and publish
./scripts/release.sh --no-bump       # Publish/retry the current version without incrementing
```

Publication uses Caterm's public R2 bucket and download domain under the separate `si/` prefix. It selects a unique Developer ID Application identity valid under macOS's code-signing policy, then requires a valid Installer identity from that team. It never switches to another team to obtain a complete pair. The defaults are Caterm's `caterm-notary` notarization profile and `caterm-r2` AWS profile. The notarization profile must belong to the selected signing team; flags/environment override the defaults, and ambiguous or missing identities stop publication. A clean committed checkout is required. Open `Install SI.pkg` inside the DMG to install in `~/Library/Input Methods`; the native macOS Installer ends with **Log Out** to finish registration. Save your work, click the button and log back in; a full Mac restart is not required by this installer. Existing apps are replaced without retaining an app backup, and a running SI blocks replacement. See [release configuration, artifacts and retry behavior](docs/RELEASING.md). Adding these scripts does not mean a public release has been published or host compatibility has been verified.

Each new release increments the last version component (`0.1.0` → `0.1.1`) and internal build number, then commits only the Xcode version file before building. Preflight failures leave versions unchanged; retries of a pending release at the same commit/architecture reuse its version. `--dry-run` prints the planned increment without changing files or Git history. See the release guide for `--no-bump`, retry state and multiple architectures.

Packaging explicitly uses HFS+ inside the compressed DMG. This avoids an APFS image-size estimation failure that can report `No space left on device` even when the Mac has ample free space; see [DMG troubleshooting](docs/RELEASING.md#dmg-creation-reports-no-space).

## Keyboard behavior

While composing, the letters at the host input caret show spaces between the
Chinese syllables or English words of the highest-ranked whole candidate:
`chileme` displays as `chi le me`, and `iwanttobuild` as `i want to build`.
Mixed candidates use both kinds of boundary. These are display spaces; editing,
prefix consumption, Return and shortcuts still use the exact original spelling.
Explicit apostrophes and casing remain intact. Unknown input stays unchanged;
provisional segmentation can change as current search results arrive.

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

Outside composition, control keys and punctuation pass through by default. Enable Show punctuation candidates in Settings → Typing to start common punctuation compositions with language-labeled alternatives for enabled languages. Shift and Caps Lock do not switch language modes. With both languages disabled, SI only offers the original text. SI's nonactivating AppKit candidate panel starts as a horizontal single line with up to six numbered choices. Short candidates such as `a` remain visible beside their numbers. Press Down Arrow or click the chevron to expand to four rows of six candidates, showing up to 24 choices at once. The entire four-row grid is one page; numbers 1–6 act on the highlighted row. Other displayed rows remain directly clickable. Each expanded column is sized for its widest visible candidate, including its number and source symbol; the window grows to show complete text within the available screen width. All rows align their numbers and text with those shared columns. The compact strip also sizes cells to their full text. Narrow screens shrink the columns to fit, with full text retained in tooltips and accessibility labels. Click the top-right chevron to collapse again. The first Down Arrow only expands and preserves the selected candidate; subsequent Down/Up presses move rows, Left/Right moves columns, and Page Up/Down changes whole grid pages. Expansion keeps the current selection and lasts until the composition ends; the next composition starts collapsed. The same shortlist is used in both layouts: six choices per collapsed page or 24 per expanded page, including each matching language identity and the exact original input. All generated Chinese dictionary characters supported by the candidate font remain pageable. Complete-syllable character lookup and character prefixes are exempt from the old preview/24-prefix limits; other word, initial/completion and sentence search remains bounded.

Number shortcuts 1–6 select within the currently highlighted row in both layouts. Other rows use dimmer numbers until they become active. Left/Right selects candidates in the collapsed strip; Down expands it without changing selection. In the expanded grid, Left/Right moves within a row and Up/Down moves between rows while preserving the column where possible. Row/column movement stops at page boundaries. Page Up/Page Down and the footer buttons change whole pages (six choices collapsed, 24 expanded), preserving the cell position where the destination has it. Space confirms the highlighted candidate. Mouse-wheel and trackpad scrolling do not change pages or selection. Home/End continue editing the composition caret.

Ordinary typing updates marked spelling before searching candidates off the main thread. A separate bounded search supplies provisional hints for the latest spelling while the full search runs, so an obsolete full search does not hold up every update. Both stages use the same decoder and maintain one running request plus one latest replacement per client. Provisional hints have narrower lexical coverage and may change when full results arrive; they do not replace the final candidate set. Only matching composition revisions may update the window. Pending hints refresh the rows without hiding the panel or shrinking its current size; mouse, page and expansion controls remain disabled until full results arrive. Space, digits, candidate navigation, and optional punctuation confirmation resolve full current candidates before selecting; these confirmation boundaries can still wait for a search. Return, Escape, and shortcuts preserve/cancel spelling without waiting.

The candidate window uses a slim warm-neutral strip, a soft peach selection pill and an orange selected number. Text remains dark in the light appearance, with a coordinated dark palette. Candidate buttons keep numbers close to their text and fit their content rather than stretching across unused space. Small arrow, pin and text symbols distinguish prefix, personal and typed-text sources in both layouts. Punctuation candidates show a small E (English) or C (Chinese) badge immediately after the text in both layouts; the exact original spelling shows A (As Typed). Full language/source details remain in tooltips and accessibility labels. The system Increased Contrast preference adds a stronger outline; page controls appear only when more than one page is available.

The candidate panel uses the first valid screen position reported for the start of the composition. It holds that anchor while typing, editing and paging. Committing, cancelling or changing focus lets the next composition pick a new position. The panel appears below the anchor when there is space and flips above near the bottom of a display.

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
crates/si-cli/          Local Rust lexicon and corpus build commands
crates/si-engine/       Shared Rust engine and resource imports
crates/si-gram/         Compact word n-gram counts through order five
crates/si-lexicon/      Compact, language-independent Rust lexicon
crates/si-benchmark/    Synthetic Rust performance benchmarks
Tests/                 Swift Testing coverage for core, storage, and settings
scripts/               Build, test, and local installation commands
docs/                  Architecture, manual checks, and roadmap
eval/                  Authored 220-query ranking regression dataset
corpus/                Pinned offline Chinese text, English dialogue and lexical reading resources
llm/                   Offline spelling-to-text training experiments (not loaded by the app)
```

The Swift package and Xcode app compile the same core source files.

### Rust engine workspace

The Rust 2024 workspace includes a language-independent lexicon with stable
word IDs, editable dictionaries, and exact and prefix lookup. The gram model
uses those word IDs to count and query ordered sequences of two to five words.
Both store raw occurrence counts. The macOS app uses the Rust engine. See
the [Rust lexicon](docs/ARCHITECTURE.md#rust-lexicon) and
[Rust gram model](docs/ARCHITECTURE.md#rust-gram-model) for storage details.

Run the checks and synthetic benchmarks from the repository root.

```sh
cargo fmt --all -- --check
cargo test --workspace --locked
cargo run --release --locked -p si-benchmark -- lexicon 1000000 100000
cargo run --release --locked -p si-benchmark -- gram 1000000 100000
```

Build and extend local Rust resources with `si-cli` on Rust 1.89 or later.
The main and user dictionaries each use a separate `.silex` file. The
example uses lookup index `0` for Pinyin and index `1` for English.

Run these scripts in order for the local base model:

```sh
./scripts/si-lexicon-build.sh
./scripts/si-corpus-ingest.sh
./scripts/si-lexicon-learn.sh
```

The build reads `Data/Chinese` and `Data/English` and requires a new
`target/si-data/main.silex` destination. The ingest reads
`corpus/chinese/prepared/raw-text-v2/*/text.txt` and adds counts to the main
lexicon and `target/si-data/words.sigram` on each completed import. The learn
script uses adjacent Han tokens from that snapshot to discover compound words
for the main lexicon. Each token may contain multiple characters. Ingest and
learn both read `config/si.conf`.

```sh
cargo run --release --locked -p si-cli -- lexicon build target/si-data/main.silex 0 Data/Chinese 1 Data/English
cargo run --release --locked -p si-cli -- lexicon build target/si-data/user.silex 0 /path/to/user-words.csv
cargo run --release --locked -p si-cli -- lexicon add target/si-data/main.silex 0 /path/to/new-words.csv
cargo run --release --locked -p si-cli -- corpus build target/si-data/main.silex target/si-data/words.sigram /path/to/tokenized.txt
cargo run --release --locked -p si-cli -- corpus add target/si-data/main.silex target/si-data/words.sigram /path/to/new-tokenized.txt
```

Ordinary lexicon imports use `text,reading,weight` CSV files. Each reading
has its own word ID and raw count. A blank reading rejects that import.
Corpus imports take one pre-tokenized UTF-8 sentence per line, with
whitespace between tokens. An ambiguous token requires an explicit
reading in `text|index|reading` form, such as `重|0|chong`.
`build` creates a new snapshot. `add` updates an existing lexicon with
absolute import totals. Repeated rows for the same index, exact text and
primary reading are summed within one invocation. Importing the same
sources again leaves those weights unchanged. Use the whole language
directory when you want the total across its category CSVs. See the
[resource workflow](docs/ARCHITECTURE.md#rust-resource-workflow) for ID and
count semantics.

[SI configuration](config/si.conf) contains the base and user learning
thresholds and separate `max_order` values under `[base]` and `[user]`.
Both default to `4` and accept `2` through `5`. To apply changes without
rebuilding the CLI, pass `--config` before the command:

```sh
cargo run --release --locked -p si-cli -- --config config/si.conf corpus add target/si-data/main.silex target/si-data/words.sigram /path/to/new-tokenized.txt
```

`max_order` controls which orders the next import counts. Changing it retains
the counts already in the snapshot. Higher orders start accumulating when
enabled, and ranking uses any available saved orders. The CLI uses bundled
settings when `--config` is omitted.

Corpus commands report the current file, byte progress, and cumulative record
and token counts on stderr while they run. The final summary goes to stdout.
The destination's `.lock` file remains available for future runs. If you
suspend an import with Ctrl+Z, use `jobs -l` and `fg %<job-number>` in the
same shell to resume it. To restart it, bring it to the foreground and
interrupt it with Ctrl+C before starting the new command.

Run `./scripts/si-corpus-prune.sh` to prune the local `words.sigram` in
place. It retains bigrams observed at least twice and trigrams observed at
least three times. The two orders are saved separately. Run discovery with
`si-lexicon-learn.sh` before pruning when learning thresholds should use the
full bigram marginals.

Use the paired lexicon to prune low-count rows from one order of an existing
gram snapshot. This example removes four-grams observed exactly once.

```sh
cargo run --release --locked -p si-cli -- corpus prune --order 4 --min-count 2 target/si-data/main.silex target/si-data/words.sigram
```

The command reports the number of rows removed and atomically replaces the
gram file in place when rows are removed. It accepts orders `2` through `5`
for word or Han-character snapshots. Counts equal to the threshold are kept.
Keep a copy of the full snapshot if you plan to accumulate counts later.
Subsequent imports start from the counts still present in the snapshot.

#### Convert typed spelling with the Rust engine

`si-cli candidates` reads UTF-8 spelling from standard input, one
composition per line. For example, after building the base dictionary:

```sh
printf '%s\n' nihao iwanttobuild woxiangyaodeploy |
  cargo run --release --locked -p si-cli -- candidates target/si-data/main.silex
```

Pass `--grams target/si-data/words.sigram` to use a paired base gram
snapshot and `--user target/si-data/profile.si-user` to include a local user
model. Both languages are enabled by default. Use `--languages zh-Hans`,
`--languages en` or `--languages none` to select a different set.

Results are TSV rows with language, consumed UTF-8 bytes, match kind,
score in bits, and output text. Backslashes and control characters are
escaped in output text. A blank line ends each result set. Nonempty inputs
have an original-text row with an empty score. The library's
[`CandidateEngine`](crates/si-engine/src/conversion.rs) returns these
candidates as typed values and can be reused across requests.

The decoder handles continuous full Pinyin and English spelling, mixed
paths, explicit Pinyin apostrophes, umlaut aliases, final-word spelling
completion and prefix candidates. The macOS app uses the same Rust
decoder through its native bridge. See [Rust conversion](docs/ARCHITECTURE.md#rust-conversion).

#### Build a local user model

Use a dedicated `.si-user` profile with an existing base lexicon. Supply
committed text explicitly as UTF-8, one sentence per line. The profile's
lexicon and word-gram counts use their own IDs and include only observations
from that profile. The base lexicon helps segment sentences. Its counts and
the base gram file stay independent.

```sh
cargo run --release --locked -p si-cli -- user ingest target/si-data/profile.si-user target/si-data/main.silex batch-001 /path/to/sentences.txt
cargo run --release --locked -p si-cli -- user learn target/si-data/profile.si-user target/si-data/main.silex
cargo run --release --locked -p si-cli -- user status target/si-data/profile.si-user
cargo run --release --locked -p si-cli -- user clear target/si-data/profile.si-user
```

Use `-` instead of a filename to read standard input. Generate an opaque
batch ID for each set of new observations and reuse that ID when retrying the
same batch. A distinct batch ID counts repeated sentences as new observations.

`user learn` uses the `[user]` section of [SI configuration](config/si.conf)
and the profile's Han-character bigrams. The defaults require five
occurrences, a 30% share in each direction, and lift of at least 2. To set
different thresholds for a profile, select a configuration with `--config`.
Learned two-character words enter Pinyin index
`0` immediately and contribute word grams on subsequent imports.

The profile stores derived words, counts and batch IDs locally. Sentence
lines and source paths are discarded after processing. On Unix the profile
directory is owner-only. `user clear` removes its derived data and batch
IDs. The Rust library entry point is
[`UserModelStore`](crates/si-engine/src/resources/user.rs).
See [user model storage](docs/ARCHITECTURE.md#rust-user-model).

#### Import unsegmented paragraphs

`corpus ingest` takes UTF-8 text with one paragraph per nonempty line. It
matches the longest exact dictionary spelling from left to right and keeps
consecutive ASCII letters together. Only known words contribute lexical
counts. An unlisted run of at least two ASCII letters breaks the word-gram
sequence and goes to a separate CSV. An isolated ASCII letter contributes `<char>`
to n-grams, and an independent ASCII digit run such as `404` contributes
one `<num>`. The paired lexicon records their IDs as unindexed, zero-count
symbols. For ambiguous Han spellings, `pinyin_pro` reads the matched word
in isolation. The importer counts the existing dictionary entry whose
reading uniquely matches the result. Spaces preserve word adjacency.
Unmatched punctuation, unknown text, and still-unresolved spellings
break the n-gram sequence.

```sh
cargo run --release --locked -p si-cli -- corpus ingest target/si-data/main.silex target/si-data/words.sigram /path/to/paragraphs.txt
cargo run --release --locked -p si-cli -- corpus ingest target/si-data/main.silex target/si-data/words.sigram /path/to/more-paragraphs.txt
```

Each import updates both specified files in place and creates missing files.
Reuse the same pair for each batch. To continue a previous directory-based
import, pass its existing `words.sigram` path and the matching lexicon.
Grams containing word IDs require their original compatible lexicon.
Seed the lexicon with Chinese readings before ingesting Chinese text you
want counted. Unlisted Chinese text goes to review.

The importer refreshes `words.sigram.english.csv` with the latest batch's
unknown English spellings. The CSV uses `text,reading,weight`, preserving
original capitalization in `text`, using lowercase lookup keys in
`reading`, and storing occurrence counts in `weight`. Keep the rows you
want to add and import the edited file into index `1`:

```sh
cargo run --release --locked -p si-cli -- lexicon add target/si-data/main.silex 1 target/si-data/words.sigram.english.csv
```

Later corpus imports can count the new entries. If an imported reading
already exists, set `weight` to the intended final count before importing.

The importer refreshes `words.sigram.review.csv` beside `words.sigram`
with unmatched characters and unresolved readings from the latest batch.
It includes occurrence counts, available readings, and the first source
file and line. Fill the final `reading` column with lowercase, toneless
Pinyin, using apostrophes between syllables. For an older review CSV, add
that column after `first_line`. Leave unconfirmed readings blank. Import
the edited CSV directly into the Pinyin index:

```sh
cargo run --release --locked -p si-cli -- lexicon add target/si-data/main.silex 0 target/si-data/words.sigram.review.csv
```

Only completed rows are imported. Their counts become the selected
readings' weights, and matching entries keep their IDs. The import
updates the lexicon only, so gram counts
from earlier batches stay as recorded. A batch with no review items
produces only the header.

Every completed import adds its counts, even if the source was imported
previously. If an import is interrupted while publishing, rerun the same
command to finish publication without recounting the corpus.

Run `./scripts/si-corpus-clear-grams.sh` to delete
`target/si-data/words.sigram`. The command preserves `main.silex`, the review
CSVs and the lock files. It waits for active writers and requires any pending
ingest publication to finish first. The next ingest starts with empty gram
counts and still adds word counts to `main.silex`.

#### Export and restore a lexicon

Run `./scripts/si-lexicon-export.sh` to export `target/si-data/main.silex`
to `target/si-data/main.silex.csv`. The export requires a new destination.

```sh
cargo run --release --locked -p si-cli -- lexicon export target/si-data/main.silex target/si-data/main.silex.csv
cargo run --release --locked -p si-cli -- lexicon export --language zh-Hans target/si-data/main.silex target/si-data/chinese.silex.csv
cargo run --release --locked -p si-cli -- lexicon restore target/si-data/main.silex.csv target/si-data/restored.silex
```

The CSV records each word's `id`, exact text, raw count, primary reading,
index, and any alias keys. Restore uses the explicit IDs even if the rows
have been reordered. Keep one word row per ID and retain the full sequence
of IDs starting at zero. Use new paths for export and restore. A restored
copy can reuse the original word gram file when each ID still refers to
the same text and primary reading.

`--language zh-Hans` selects Pinyin entries and `--language en` selects
English entries by primary reading index. Both use the same snapshot
columns and preserve original IDs and aliases of the selected words.
Use a full export for restoration because filtering can leave gaps in the
word IDs. Continue editing the three-column source CSVs under `Data/` for
`lexicon add`.

#### Learn Chinese words from a corpus

`lexicon learn` reads the bigram table and joins adjacent Han tokens when
their count, forward share, backward share, and lift meet the thresholds.
With a word model, it can join tokens such as `数据` and `库` to learn
`数据库`. Earlier gram counts keep the segmentation used when they were
recorded. Newly learned words can participate in grams from subsequent
imports. Edit [the `[base]` section of SI configuration](config/si.conf) to
select the Pinyin index and set the four bigram thresholds.

For two-character discovery from a character model, seed the lexicon with
single Han characters and their full Pinyin readings. The `--han` option
accepts ordinary UTF-8 text and counts contiguous characters.

```sh
cargo run --release --locked -p si-cli -- lexicon build target/si-data/learned.silex 0 /path/to/han-seed.csv
cargo run --release --locked -p si-cli -- corpus build --han target/si-data/learned.silex target/si-data/characters.sigram /path/to/corpus.txt
cargo run --release --locked -p si-cli -- --config config/si.conf lexicon learn target/si-data/learned.silex target/si-data/characters.sigram
```

The starting configuration requires at least 40,000 occurrences, at
least 4 percent in each direction, and 10 times the expected independent
co-occurrence.
For `重庆`, the forward share uses all bigrams starting with `重` and the
backward share uses all bigrams ending with `庆`. Lift divides the
observed co-occurrence by the expected count from those two marginals.
Set a share or lift threshold to zero to disable that check. Older
configurations can still include the order-3 and order-4 settings.
Corpus commands count through the configured `[base]` maximum order.
For each qualifying candidate, `pinyin_pro` reads the whole word together.
A complete reading is added to the lexicon with the original gram count.

Use `corpus add --han` with each new corpus once, then rerun learning to
add newly qualifying words. Existing words keep their IDs, counts, and readings.

If the reader cannot produce a complete reading, the command puts the
candidate in a numbered review CSV beside the lexicon. The first
export for `learned.silex` is `learned.silex.review-1.csv`. Each row
keeps the original gram count and has an empty `reading` field. Fill the
correct full Pinyin reading using apostrophes between syllables, and remove
any rows you do not want to add. Import the reviewed CSV after supplying
a reading for every remaining row.

```sh
cargo run --release --locked -p si-cli -- lexicon add target/si-data/learned.silex 0 target/si-data/learned.silex.review-1.csv
```

Later exports use a fresh number so you can keep earlier edits. These
count and share thresholds can still admit common fragments, so corpus
coverage and word quality require separate evaluation.

## Model training experiments

The [ranking evaluation dataset](eval/README.md) contains 220 synthetic queries
covering documented Pinyin regressions, 100 short Chinese ambiguity cases, English
hard cases, source aliases, and seeded Chinese, English and mixed sentences.
It stores inputs and intended outputs for evaluation with candidates from the
current engine. Run `python3 scripts/generate_ranking_eval.py --check` to verify integrity
and reproduction. The former ranking/correction/conversion registry was removed.
These synthetic, correlated cases are regression evidence, not an independent
production accuracy estimate.

The [model workspace](llm/README.md) contains offline Pinyin-to-text
training, small-model training, supplied-candidate scoring and inference
export. A larger reranker is planned.

The independent [corpus workspace](corpus/README.md) prepares pinned public Chinese conversation, web, Wikipedia and technical-documentation text, with per-source licenses, line origins and integrity reports. The complete-text extractor also accepts explicit local SI TXT and dialogue collections, including the eight-format Chinese Chatbot Corpus importer, converts extracted text with OpenCC t2s, and preserves repeated occurrences; its new outputs use `prepared/raw-text-v2`. Chinese Wikipedia acquisition resolves the latest complete official article dump and verifies its official checksum before recording the pin. It also exports explicit character/word readings from the maintained vocabulary. The separate [English conversation collection](corpus/english/README.md) acquires PersonaChat/ConvAI2, BST, Topical-Chat, Taskmaster 1/2/3, ABCD, SGD and English OASST1 messages, preserving dialogue/turn identity, data terms and upstream splits. Raw and prepared data stay local and outside Git. These preparation stages do not label sentence Pinyin, change existing training defaults or integrate a model into SI.

Git retains the application dictionary CSV sources, manifests, preparation/training code, configs, source pins, attribution, authored training CSVs and frozen regression fixtures. Generated databases, downloads, generated corpus tables, prepared datasets, Python environments and training outputs are ignored. See [the data policy](CONTRIBUTING.md#local-corpus-and-model-artifacts) and the corpus/model guides to recreate local artifacts; removing them from tracking preserves local copies and does not rewrite earlier Git history.

[The independent `llm/` framework](llm/README.md) now defaults to a randomly initialized 19.7M encoder-decoder for Pinyin-to-Han characters and short words. Its [focused static CSVs](llm/pinyin_to_text/data/pinyin-csv/README.md) use explicit `train/`, `validation/` and `test/` directories with `characters.csv` and `words.csv` groups. Preparation freezes maintained rows and source hashes without generating sentences, Pinyin, typos or random splits. This experiment excludes sentence templates, English/mixed and typo sources; those earlier experiments remain available separately. Representative converter quality and native converter deployment remain unverified; native neural ranking has been removed pending redesign. Default model sources exclude live Personal Learning, personal phrases, Input History and retired archives. Explicitly volunteered history exports can separately become reviewed offline training observations through [the export workflow](docs/INPUT_HISTORY_EXPORT.md); no live collection or automatic training is connected.

Each preset script performs one task: run `./llm/pinyin_to_text/scripts/setup.sh` for the environment, `./llm/pinyin_to_text/scripts/data.sh` for CSV preparation, `./llm/pinyin_to_text/scripts/run.sh` for small-model training on MPS, then separately run `validation.sh`, `test.sh`, `infer.sh` or `export.sh` as needed. Shared paths and parameters are in `llm/scripts/defaults.sh`; no stage launches the next one. The scripts use `llm/.venv` without activation and accept explicit argument overrides. Old environment overrides still take precedence; use a fresh terminal before using the new presets. Use `check.sh` and the tiny CPU `smoke.sh` for framework checks. See [the framework guide](llm/README.md) for preset locations and new-run/resume instructions.

The focused collection initially has 2,021 training pairs (937 character/readings and 1,084 short words), 73 validation and 69 test pairs. Its audit records the one-time vocabulary selection and training-only character alignment. This is limited coverage and does not establish held-out word quality. The earlier [50,000-sample collection](llm/pinyin_to_text/data/csv/EXPANSION_50K.md), 0.403B config, prepared snapshots and checkpoints remain unchanged for explicit use; old weights do not resume into the smaller architecture.

## Website

The static website supports English and Simplified Chinese, with dedicated Privacy and Terms pages and an accessible scripted input demonstration. It highlights offline, on-device typing while explaining the separate user-initiated update connection and independently opted-in local data. Its download section offers separate Apple Silicon (arm64) and Intel (x86_64) images from the published R2 channels, each with its matching checksum and source archive. Build it with `node scripts/build-website.mjs`; see [website development and GitHub Pages deployment](docs/WEBSITE.md) for preview, localization, download updates, and custom-domain setup.

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) and the [architecture](docs/ARCHITECTURE.md). Keep code, source localization keys, documentation, issue reports, and pull requests in English. App translations, language data and user input retain their original scripts.

See the [roadmap](docs/ROADMAP.md) for planned work and [manual verification](docs/TESTING.md) for host-app checks. Run core tests and macOS builds locally; GitHub Actions retains only the website workflow.

Use `./scripts/benchmark.sh` for synthetic candidate-generation timings.
It covers Chinese, English, mixed spelling, saved preferences, personal
phrases and synchronous/deferred editing. [Candidate ranking](docs/UNIFIED_RANKING.md) · [Verification status](docs/VERIFICATION.md)

## License

SI is licensed under the GNU General Public License, version 3. Dictionary
sources retain their own terms, including Wanxiang CC BY 4.0 and Cloudflare
Radar CC BY-NC 4.0. Historical source notices accompany retained vocabulary.
[GPLv3](LICENSE) · [Dictionary provenance](docs/DICTIONARIES.md)
