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
engine calculates word frequency as the word's count divided by the total
count across the dictionary, including Chinese and English. Word grams score
continuations across languages using the same rule. At each gram order, the
score retains at least 20% of the lower-order probability. Spelling costs
apply to incomplete or edited matches. Complete candidates precede prefixes.
Prefixes sort by decreasing consumed length, then by score within the same
range. The exact original input stays available for every nonempty
composition. [Rust conversion architecture](docs/ARCHITECTURE.md#rust-conversion)

The local Sentence Learning model uses the same count rule within its own
dictionary. User word frequencies and word grams contribute bounded increases
to the underlying statistical score.

Rust library callers can opt into bounded, single-edit Pinyin suggestions
with `CandidateEngine::with_pinyin_correction(true)`. For a CLI preview, add
`--pinyin-correction on` to `si-cli candidates`. In the macOS app,
**Pinyin correction** is on by default and can be turned off under Typing.
The first displayed candidate gets the default highlight, including a spelling
correction. Space confirms the highlighted candidate.
Contextual statistical scoring runs in both correction modes. With correction
enabled, a suggestion must clear the engine's conservative confidence margin
after its spelling-edit cost. Whole spelling suggestions, completions and
ordinary whole candidates then compete by score. Resource-local caches reuse
dictionary transitions and prepared word-gram contexts across edits.

A correction in an earlier completed word can continue into a bounded final-word
completion. For example, `wobuzhdaonishibushiyige` can suggest
`我不知道你是不是一个`; appending `x` keeps that correction available while
completing the last word, such as `我不知道你是不是一个新`. Corrected
completions must also beat ordinary whole-input completions by the correction
confidence margin. They keep exact typed source spans and require explicit
acceptance; Return still submits the original spelling.

**Local model ranking** is on by default and can be turned off under Typing.
The bundled small character model scores up to 12 eligible whole-input
candidates in statistical order, without a score-gap cutoff. The setting is independent
of Pinyin correction. The model runs on-device and can add up to two bits to an
eligible candidate's statistical score. SI uses the statistical order whenever
model scoring is unavailable.
[Scoring and bounds](docs/ranking-architecture.md#local-model-ranking)

In compatible macOS text fields, SI passes the full text before the composition
to the local Rust engine. The engine uses word grams from the fragment after
the last explicit sentence/fragment delimiter to help rank candidates. A
confirmed empty prefix or a boundary followed only by whitespace starts a new
fragment and uses base `<s>` statistics. Openings compete with enabled
language candidates consuming the same source span. Let `r` be the opening's
probability divided by the highest probability among its competitors; the
shared global denominator cancels, so counts can be compared directly.
The reward is `2*r*r*(3-2*r)` bits: two bits for the strongest observed
opening, smoothly decreasing to zero for an unseen opening, without subtracting
from the ordinary score. Exact matches, completions and corrected spellings
use separate comparison groups so unfinished suffixes cannot change an exact
prefix's reward. This context stays in memory. Unavailable host text does not
imply sentence start; conversion uses the composition and local resources as
usual. Boundary statistics must be present in the paired base resources.

The Rust engine owns final candidate merging, ordering and window shortlisting; Swift owns window layout and client-local selection. The window uses one 27-choice ordinary shortlist, including the exact original input, and additionally retains every generated exact Chinese dictionary character. Spelling corrections, constructed sentences, multiword fragments and dictionary completions qualify through the original first four ranked choices, subject to the length-based sentence budget below; statistical leaders have no reserved slots. At most nine exact word choices (including exact prefixes and personal phrases) are retained in engine order, independently of Chinese dictionary characters and punctuation. Completions count as constructed results even when they come from a single dictionary entry. Chinese, English and mixed hypotheses share the same four-choice eligibility without language reservations. Candidates are shortlisted without checking system font coverage; rare characters remain pageable. All retained nonliteral choices keep engine order, without language reservations, and the exact original input stays last. Prefix choices consume only their exact source spelling. For example, choosing `比如` from `biruzhege` leaves `zhege` editable. With `sheguofennudehai`, generated character choices remain pageable, allowing `涉` → `过` → `愤怒` → `的` → `海` to be selected individually. Tooltips and accessibility descriptions retain the exact consumed spelling. Return commits exact remaining spelling. Live host compatibility remains unverified.

The leading constructed candidate's output length determines one shared window
budget for sentences, multiword prefixes, spelling corrections and completions.
Length counts nonwhitespace graphemes, so combining marks and emoji sequences
count as displayed characters.

| Leading constructed output length | Maximum constructed candidates |
| --- | --- |
| Fewer than 6 characters | 4 |
| 6 characters | 3 |
| 7–8 characters | 2 |
| 9 or more characters | 1 |

The window keeps candidates in ranked order within the original four-choice head.
It does not fill removed sentence slots with lower-ranked constructed results.
Exact words and Chinese dictionary characters retain their existing budgets;
original literal input stays available. Full engine and Settings previews retain
all conversion results. No score-gap, relative-word-frequency or completion-stem
filter is applied by this window policy.

For `cichuxiande`, the single-character prefix `词` has the same lexical score as standalone `ci`, regardless of how `chuxiande` could convert. Choosing `词` leaves that exact remainder editable; the intended full sentence is not guaranteed as the first choice.

Ordinary conversion runs locally. SI has no analytics, raw-keystroke logging, or cloud dependency for ordinary typing. Optional, user-initiated software update checks contact SI's download service without sending input or personal phrases. Language and learning settings are saved in UserDefaults. Personal Learning and Input History are independently off by default. Personal Learning retains aggregate candidate preferences. Sentence Learning builds a local user model from eligible input fields passed through Return or Command–Return. Input History can retain each submitted spelling and text pair permanently on this Mac. Separately enabled AI completion can send composition and app context to a selected provider. See [personalization and privacy](docs/PRIVACY.md) for retained fields, retention, pause, deletion, and storage limitations.

Debug and Release bundle `Data/Engine/main.silex` and
`Data/Engine/words.sigram`. Xcode validates the paired snapshots before
staging them, and SI opens them before starting the input-method server.
The word-gram snapshot is tracked in Git, and `main.silex` is generated locally
from the maintained CSVs. See [engine resources](Data/Engine/README.md)
for validation, source notices and maintenance.

Candidate positioning queries the host for the start of the marked spelling after layout. The first usable start position anchors the panel while you type, delete, wrap lines or move the composition caret. Prefix confirmations keep that original anchor until the remaining spelling is fully committed or cancelled. The panel stays within the display's visible area and can flip above the anchor when it needs more room. If the host returns no usable geometry, SI uses the last valid location for that text client or the mouse position while awaiting a usable start. See the [native positioning checks](docs/TESTING.md#candidate-positioning) for host verification.

Inline spelling uses InputMethodKit's thin, unselected underline style, with display-only spaces between decoded syllables or words. The spelling remains a composition until confirmation, so candidates, caret editing and cancellation remain available. Hosts control the final appearance and any suggestions or autocomplete during composition; live behavior in ChatGPT and browser address bars requires verification. See [inline composition checks](docs/TESTING.md#inline-composition-presentation).

## Input languages

The macOS input-source menu for SI includes independent **English** and **Chinese (Simplified)** checkmarks. Click either to enable or disable that input language without opening Settings. These global preferences stay synchronized with Settings and allow both languages together or neither (exact original input remains available). Changing a checkmark refreshes the active composition without committing its spelling or moving its caret. No keyboard shortcut is assigned. Per-application direct input still takes precedence; to convert Chinese in an app such as Terminal, first turn off its direct-input rule in Settings.

## SI Settings

Open **SI Settings…** from the input menu. **Typing** opens first, with language and composition controls. **AI Completion** is a separate page under **Input**. Use the sidebar or search for a setting such as “punctuation”, “export” or “screen recording”. **Personal Data** groups Personal Phrases, Personal Learning and Input History into separate pages. Experimental permissions and software updates are under **System**.

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
For a targeted frequency change in an existing snapshot, use
`si-cli lexicon update <lexicon.silex> <index> <reading> <text> <count>`.
For example, `lexicon update Data/Engine/main.silex 0 ba 把 120000000` sets
only that primary word identity's count. It does not modify the source CSVs,
other entries, word IDs, lookup aliases or paired word grams. A missing identity
fails instead of adding a word. The count is absolute, including zero; it is
not an increment. To append one new primary identity, use
`si-cli lexicon add <lexicon.silex> <index> <reading> <text> <count>`.
It assigns a new word ID while preserving existing entries and paired grams.
An existing index/reading/text identity fails without changing its count.
Both commands require an existing snapshot and leave source CSVs unchanged.
The former CSV form of `lexicon add` and `lexicon import` are no longer
accepted. To incorporate changed CSVs in bulk, build
a fresh dictionary and regenerate its paired grams. A fresh build takes its
counts from the supplied sources; it does not retain offline frequency edits
unless they are reflected in those sources. Rebuild/reinstall the app
to package an offline snapshot change; already loaded engines do not reload it.
To remove entries, build a fresh lexicon at a new path and regenerate its
paired word grams from the selected corpus before using them in the app.

## Automatic prefix confirmation

Enable **Automatically confirm stable prefixes** in **SI Settings → Typing** to let SI confirm leading Chinese words while you continue typing or pause. It is off by default. SI keeps at least four output characters editable during continuous typing, or two after a pause of at least 1.8 seconds; complete-word boundaries can leave a longer ending. Only the confirmed source spelling is consumed, and the remaining exact spelling stays marked and editable without an extra space.

Automatic confirmation requires matching source/output boundaries across nearby full-search alternatives. Continued typing must also preserve the prefix across multiple results with additional input. A pause relaxes the ending length, but requires a prefix of at least two characters and does not override disagreement between candidates. Ambiguous input can remain entirely editable. English/mixed leaders, uppercase/code-like spelling, personal phrases and unrecognized spans are excluded. These are conservative local heuristics, not a guarantee of sentence meaning or a way to predict whether later typing will turn a spelling into an identifier.

Editing, moving the caret, navigating/expanding candidates, or crossing a host boundary cancels automatic confirmation; fresh typing at the composition end starts new evidence. Settings changes, secure input, cancellation and obsolete confirmation evidence cannot authorize a pending confirmation. Each pause can confirm at most once until more input arrives. Automatic confirmation does not train Personal Learning. If separately enabled, Input History records its submitted prefix like other SI commits. Return and shortcuts preserve only the remaining spelling once a prefix has been committed; editing already committed text uses the host application's normal editing tools. Native timer/focus behavior still requires the checks in [testing](docs/TESTING.md#automatic-prefix-confirmation).

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

Sentence Learning reads up to the first 2,048 UTF-16 units of the active field before a passed-through Return or Command–Return. If the client rejects that range, SI can use the available text from the start of the field to a caret within the same limit. If the readback still contains the original snapshot, SI skips ingestion. If the field is cleared, replaced, loses focus or becomes unreadable, SI learns from the earlier snapshot. This can learn a sentence assembled from individual selections and subsequently edited. Secure and direct input are excluded. Return consumed by an active SI composition submits the remaining spelling to the field. Personal Learning independently uses confirmed candidate selections.

SI batches learning text in memory and reuses the Rust ingestion and word discovery behind `si-cli user ingest` and `si-cli user learn`. Only derived words, counts and batch IDs are saved. On upgrade, SI removes the old recent-samples files and keeps the existing derived model. Use **Personal Phrases → Delete All…** to clear the local vocabulary and word grams. See [sentence learning privacy and retention](docs/PRIVACY.md#sentence-learning) and [native checks](docs/TESTING.md#sentence-learning).

## Input History

Open **SI Settings → Input History** and enable **Save Input History**. It is independently off by default; enabling Personal Learning or a language does not enable history. Each successful SI composition submission keeps the exact consumed spelling, submitted text, timestamp, language/mixed identity and commit reason. Examples include `nihao` → `你好`, English conversion and original English/code committed with Return. SI-inserted spaces/punctuation are retained in the submitted output. Repeated submissions remain separate rows. Prefix selection and automatic confirmation each save only their submitted portion, leaving the pending remainder unrecorded until it is committed.

**History has no automatic expiry or record-count limit.** It stays on this Mac until you explicitly delete it. The 5,000-entry Personal Learning cap does not apply. History does not affect ranking, create completions or enter model training automatically. **View Input History…** offers spelling/text search and newest-first pages of up to 100 records, with individual Delete and **Clear Input History…**. Clearing learning/phrases/history affects only the chosen data category. Disabling history stops new recording while keeping saved records; accepted pending writes still finish.

History includes literal, personal-phrase, punctuation and automatic SI submissions when enabled. It does not capture cancelled compositions, raw keystrokes, document/clipboard text, standalone keys passed to the host outside composition or text in direct-input apps. Secure event input suppresses recording; it cannot detect every sensitive field. Recording is checked before and after the host insertion call, including consent generation changes during reentrant callbacks. Data is prospective: past input and retired history archives are not imported.

**Export Input History…** saves all persisted history as one versioned JSONL file, including records hidden by search. The action opens a save panel directly, with no backup/training distinction or purpose flag. Export never uploads or sends a file. It contains private source/output text and timestamps, and deleting local history does not delete exported copies. Accepted writes finish before export; pending save failures must be resolved first.

The receiver can run `python3 scripts/input_history.py inspect FILE.jsonl`, `restore FILE.jsonl --output NEW.sqlite3`, or `prepare FILE.jsonl --output NEW_DIRECTORY`. Restore validates versions/count/checksum and recreates every event exactly. Training preparation accepts the same export and produces an unsplit candidate CSV plus provenance for review, without modifying existing data or starting training. See [export/restore and training-observation workflow](docs/INPUT_HISTORY_EXPORT.md).

For text-only copies of Input History or earlier Sentence History exports, run `python3 scripts/input_history_to_txt.py`. It converts the JSONL files in `corpus/chinese/raw/input-history/` to adjacent same-name `.txt` files containing only submitted text (`output`), in original order with repeats preserved. You can also pass a file or directory; existing TXT files require `--overwrite`. See [plain-text extraction](docs/INPUT_HISTORY_EXPORT.md#plain-text-extraction).

The independent owner-only SQLite database is `~/Library/Application Support/SI/InputHistory/history-v1.sqlite3`. It is not encrypted; private text can be accessible to other software running as you, administrators and backups. I/O stays off the main actor/key-event path. Writes are serialized and transactional, retries do not duplicate a submission, and clear cannot be undone by older pending writes. Open/save failures visibly pause recording; failed writes remain in memory for **Retry Saving History**, and corrupt/unsupported files remain untouched until explicit clear. Normal termination waits for queued writes; forced termination, disk failure or quitting without retry can lose unsaved entries. External backups remain outside SI's deletion controls. See [privacy](docs/PRIVACY.md#input-history) and [manual checks](docs/TESTING.md#input-history).

## Personal phrases

Open **SI Settings → Personal Phrases** to view and search the active `user.silex` entries. Add, edit or delete words, their Pinyin/English readings and frequency counts directly. This is the same private vocabulary that Sentence Learning updates and SI uses for conversion.

The former separate shortcut dictionary, pins and JSON import/export have been removed from the app. Existing `phrases-v1.json` files are left untouched and are no longer loaded or migrated. Edits atomically update the paired user model; deleting or changing a word identity removes its associated word grams while keeping unrelated entries and counts. **Delete All…** clears the shared vocabulary and word grams, including queued learning. See [storage and controls](docs/USER_PHRASES.md).

## Requirements

- macOS 14 or later.
- Xcode 26 or later with Swift 6.2 or later and the macOS SDK.
- Rust 1.89 or later with the `aarch64-apple-darwin` and `x86_64-apple-darwin` targets for a universal app.
- Xcode resolves the pinned Sparkle 2.10.0 update framework on the first app build. Unsigned development builds require no Apple Developer account.

## Get started

```sh
git clone https://github.com/caterm-dev/si.git
cd si
./scripts/test.sh
```

Generate a missing `Data/Engine/main.silex` with
`./scripts/si-lexicon-build.sh`, then validate the pair following
[engine resources](Data/Engine/README.md). Run `./scripts/build.sh` to
package the local lexicon and matching `words.sigram`. The application is built
at `.build/xcode/Build/Products/Debug/SI.app`. See the
[resource preparation commands](#rust-engine-workspace).

The build compiles the Rust bridge. The test script builds a separate fixture
dictionary from the tracked CSVs. Private user snapshots, history databases,
experimental resources and build outputs stay under ignored local paths.

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
Explicit apostrophes and casing remain intact. Input without a whole match
keeps its original spelling.

| Key | During composition |
| --- | --- |
| Letters | Insert into the English/Pinyin composition at its caret |
| Apostrophe | Separate Pinyin syllables, e.g. `ni'hao` |
| Space | Commit the selected candidate without adding a trailing space |
| Return / Enter | Commit the original text without adding a newline |
| Left / Right | Select the previous/next candidate when collapsed; move columns when expanded |
| Home / End | Move to the start/end of the composition |
| Up / Down | Down expands first. In the expanded list, move one row and scroll as needed |
| Page Up / Page Down | Move one row when collapsed or up to five rows when expanded |
| 1–6 | Select candidates on the highlighted row |
| Delete / Forward Delete | Remove the previous/next composition character at the caret |
| Escape | Cancel the composition |
| Punctuation / symbols | Stay editable in the composition by default; optional punctuation confirmation is configurable |
| Tab | Apply the configured composition-boundary behavior |
| A shortcut | Commit original spelling and pass the event through |

Space, number and mouse confirmation insert one leading space only at a Chinese–English
boundary: English after Chinese, or Chinese after English. SI checks the actual
first character of the submitted text and the adjacent preceding host character,
including mixed, prefix and explicitly confirmed literal choices. Existing spaces,
same-language boundaries, punctuation, digits and the beginning of a field are left
alone. Confirmation never adds a trailing space. Return and shortcuts still submit
the exact original spelling. Boundary reads are transient and skipped for secure/direct
input. Hosts that expose native text and a document caret can use a validated
readback even when the marked range is unavailable. With a known marked range,
SI reads only the preceding boundary and does not require the host to expose the
underlined spelling. Native responses covering a larger range are sliced to the
requested boundary. Unsupported hosts submit without guessing a separator.

Outside composition, control keys and punctuation pass through by default. Enable Show punctuation candidates in Settings → Typing to start common punctuation compositions with language-labeled alternatives for enabled languages. Shift and Caps Lock do not switch language modes. With both languages disabled, SI only offers the original text. SI's nonactivating AppKit candidate panel starts as a horizontal single line with up to six numbered choices. Short candidates such as `a` remain visible beside their numbers. Press Down Arrow or click the chevron to expand to five rows of six candidates, showing up to 30 choices at once. The expanded grid is a continuous list. Numbers 1–6 act on the highlighted row, and every visible candidate can be clicked. Each expanded column is sized for its widest visible candidate, including its number and source symbol; the window grows to show complete text within the available screen width. All rows align their numbers and text with those shared columns. The compact strip also sizes cells to their full text. Narrow screens shrink the columns to fit, with full text retained in tooltips and accessibility labels. Click the top-right chevron to collapse again. The first Down Arrow expands and preserves the selected candidate. The list stays expanded until you collapse it or end the composition. Both layouts use the same shortlist, including matching language identities and the exact original input. All generated Chinese dictionary characters supported by the candidate font remain pageable. Complete-syllable character lookup and character prefixes are exempt from the bounded word and composed-prefix search; other word, initial/completion and sentence search remains bounded.

Number shortcuts 1–6 select within the currently highlighted row in both layouts. Other rows use dimmer numbers until they become active. Left/Right selects candidates in the collapsed strip; Down expands it without changing selection. In the expanded grid, Left/Right moves within a row. Up/Down moves between rows, preserving the column where possible and scrolling one row when the selection reaches the edge of the visible list. Page Up/Page Down moves one row when collapsed or up to five rows when expanded. Space confirms the highlighted candidate. Home/End continue editing the composition caret.

Each typing or deletion event synchronously runs full conversion, then updates the marked spelling and candidate window with that completed result. The first displayed candidate is highlighted, numbers remain visible, and keyboard, mouse, paging and expansion controls use the same current list. Space confirms the selected candidate. Return and shortcuts preserve the spelling, and Escape cancels it. Search completes before the next event is handled, so long compositions can delay input. Vocabulary resources load once during application startup.

The candidate window uses a slim neutral strip. The selected candidate has a solid system accent background, blue by default, with white text and numbering. Candidate buttons keep numbers close to their text and fit their content rather than stretching across unused space. Small pin and text symbols distinguish personal and typed-text sources in both layouts. Punctuation candidates show a small E (English) or C (Chinese) badge immediately after the text in both layouts; the exact original spelling shows A (As Typed). Full language/source details remain in tooltips and accessibility labels. The system Increased Contrast preference adds a stronger outline.

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
eval/                  Decoder recall, fixed-pool ranking, and window regressions
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

For an existing paired base model, prepare and ingest new corpus observations,
then run word discovery:

```sh
corpus/.venv/bin/python corpus/prepare_si_raw_text.py
./scripts/si-corpus-ingest.sh
./scripts/si-lexicon-learn.sh
```

The CSV import wrapper has been removed. A targeted `lexicon add` or
`lexicon update` does not require re-ingesting the corpus. For a fresh rebuild from `Data/Chinese` and
`Data/English`, pass a temporary output path to `si-lexicon-build.sh`,
regenerate matching word grams, then replace both
resource files in `Data/Engine/`. The preparation command extracts
the three local collections documented in the [corpus guide](corpus/README.md).
The ingest reads `corpus/chinese/prepared/si-corpus/*/text.txt`, charges one bit
per additional segment when splitting the text, and adds counts to the main
lexicon and `Data/Engine/words.sigram` on each completed import. Rebuild from a
fresh lexicon and gram snapshot to apply the rule to previously counted text.
The learn script uses adjacent Han tokens from that snapshot to discover
compound words for the main lexicon. Each token may contain multiple
characters. Ingest and learn both read `config/si.conf`.

```sh
cargo run --release --locked -p si-cli -- lexicon build .build/si-data/fresh.silex 0 Data/Chinese 1 Data/English
cargo run --release --locked -p si-cli -- lexicon build .build/si-data/user.silex 0 /path/to/user-words.csv
cargo run --release --locked -p si-cli -- lexicon update Data/Engine/main.silex 0 ba 把 120000000
cargo run --release --locked -p si-cli -- lexicon add Data/Engine/main.silex 0 "shi'li'ci" 示例词 1000
cargo run --release --locked -p si-cli -- corpus build Data/Engine/main.silex Data/Engine/words.sigram /path/to/tokenized.txt
cargo run --release --locked -p si-cli -- corpus add Data/Engine/main.silex Data/Engine/words.sigram /path/to/new-tokenized.txt
```

Ordinary lexicon imports use `text,reading,weight` CSV files. Each reading
has its own word ID and raw count. A blank reading rejects that import.
Corpus imports take one pre-tokenized UTF-8 sentence per line, with
whitespace between tokens. An ambiguous token requires an explicit
reading in `text|index|reading` form, such as `重|0|chong`.
`lexicon build` creates a new snapshot from the supplied CSV totals.
Repeated rows for the same index, exact text and primary reading are summed
within one invocation. Use the whole language directory when you want the
total across its category CSVs. `lexicon update` sets one existing identity's
count and `lexicon add` appends one new identity without rebuilding. Both
accept nonnegative u64 counts, including zero. CSV imports into an existing
snapshot are not supported. See the
[resource workflow](docs/ARCHITECTURE.md#rust-resource-workflow) for ID and
count semantics.

[SI configuration](config/si.conf) contains the base and user learning
thresholds and separate `max_order` values under `[base]` and `[user]`.
Both default to `4` and accept `2` through `5`. To apply changes without
rebuilding the CLI, pass `--config` before the command:

```sh
cargo run --release --locked -p si-cli -- --config config/si.conf corpus add Data/Engine/main.silex Data/Engine/words.sigram /path/to/new-tokenized.txt
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
cargo run --release --locked -p si-cli -- corpus prune --order 4 --min-count 2 Data/Engine/main.silex Data/Engine/words.sigram
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
  cargo run --release --locked -p si-cli -- candidates Data/Engine/main.silex
```

Pass `--grams Data/Engine/words.sigram` to use a paired base gram
snapshot and `--user .build/si-data/profile.si-user` to include a local user
model. Both languages are enabled by default. Use `--languages zh-Hans`,
`--languages en` or `--languages none` to select a different set.

Use `--list window` to apply the same Rust final statistical ordering and
candidate shortlist policy used by the app. The default `--list full` retains
the complete conversion results. This selects candidates only; window layout,
paging and session state remain with each platform. The CLI does not load the
app's Personal Learning preferences, personal phrases, punctuation options or
local character reranker.

To inspect full-Pinyin suggestions for missing letters, neighboring-key
substitutions, and adjacent transpositions, pass `--pinyin-correction on`.
Use `--pinyin-correction higher-recall` to lower the confidence margin.
With a paired gram snapshot, pass `--preceding '找。想'` to supply the same
synthetic preceding text for every input line.
The match kind for these suggestions is `correction`. For example,
`nihoa` can suggest `你好` while leaving the literal `nihoa` available.
See the [Pinyin correction evaluation](docs/TESTING.md#pinyin-correction-evaluation)
for a repeatable quality and latency comparison.

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

Run `./scripts/si-copy-user-model.py` to copy the installed SI user's active
`user.silex` and `user.sigram` into `.build/si-data/`. The script replaces
previous copies with the current pair and gives both files owner-only access.
The copies stay local and are ignored by Git. Clearing Personal Phrases in
SI leaves these copies on disk. To remove them, delete both files from
`.build/si-data/`.

Use a dedicated `.si-user` profile with an existing base lexicon. Supply
committed text explicitly as UTF-8, one sentence per line. The profile's
lexicon and word-gram counts use their own IDs and include only observations
from that profile. The base lexicon helps segment sentences. Its counts and
the base gram file stay independent.

User ingestion automatically adds English words with lowercase lookup keys
and preserves their output casing. For new ASCII letter runs, an exact English
word in the base lexicon takes priority, ignoring ASCII case. Otherwise, a run
that can be fully segmented into Pinyin syllables is skipped, without adding
word counts or joining word grams across it. Unknown runs that are not complete
Pinyin remain eligible. This spelling check uses the pinned `pinyin_pro` reading
data, without abbreviations, completion or typo correction. Existing user entries
are retained and keep their observation behavior.

User ingestion saves a common unquoted ASCII email address such as
`Reader89+work@example.com` as one word and gram token.
A web address supplies its domain and any explicit HTTP(S) scheme as one user
word and one token in word grams.
For example, `https://example.com/Docs?q=KeepCase#Section` supplies
`https://example.com`, and `example.com/Docs` supplies `example.com`.
User info, ports, paths, query strings and fragments are discarded. Isolated
ASCII letters are excluded from new vocabulary and gram observations and
break word adjacency, even if already listed in a lexicon. Existing entries
and counts are retained. Base `corpus ingest` retains its review and placeholder rules.

```sh
cargo run --release --locked -p si-cli -- user ingest .build/si-data/profile.si-user Data/Engine/main.silex batch-001 /path/to/sentences.txt
cargo run --release --locked -p si-cli -- user learn .build/si-data/profile.si-user Data/Engine/main.silex
cargo run --release --locked -p si-cli -- user status .build/si-data/profile.si-user
cargo run --release --locked -p si-cli -- user clear .build/si-data/profile.si-user
```

Use `-` instead of a filename to read standard input. Generate an opaque
batch ID for each set of new observations and reuse that ID when retrying the
same batch. A distinct batch ID counts repeated sentences as new observations.

`user learn` uses the `[user]` section of [SI configuration](config/si.conf)
and bigrams from the profile's `user.sigram`. It joins adjacent Han tokens
with full Pinyin readings from `user.silex`. The defaults require five
occurrences, a 30% share in each direction, and lift of at least 2. To set
different thresholds for a profile, select a configuration with `--config`.
Learned compounds enter Pinyin index
`0` immediately and contribute word grams on subsequent imports.

The profile stores derived words, word grams and batch IDs locally.
App submissions and CLI imports discard the source text after processing.
Opening a valid word pair removes obsolete character and recent-sample files.
On Unix the profile directory is owner-only. `user clear` removes its derived
data and batch IDs. The Rust library entry point is
[`UserModelStore`](crates/si-engine/src/resources/user.rs).
See [user model storage](docs/ARCHITECTURE.md#rust-user-model).

#### Generate synthetic chat locally with Pi

Configure Pi's `ollama` provider to use a local Ollama server with
`qwen3.8:27b` installed. The 1,000 suggested scenes are grouped into
50 categories in `TOPICS` in
[`scripts/si-generate-chat-corpus.py`](scripts/si-generate-chat-corpus.py)
and can be filtered with repeatable `--topic` options such as `--topic family`.
The script reads `Data/Chinese/base.csv` in row order and visits each distinct
written form once. To generate three new dialogues, run:

```sh
python3 scripts/si-generate-chat-corpus.py --limit 3
```

Each batch starts a fresh Pi process with thinking enabled at low effort.
The default batch size is five target words. Use `--batch-size 10` to try
ten at a time, or `--batch-size 1` for one word per request. Each word gets
its own scene and style suggestions. Pi can choose a scene that better fits
the word. The script retries missing or invalid batch results individually.
A dialogue must contain the exact target
text in a message before the script appends it to
`corpus/chinese/raw/si/pi/messages.txt`. The file contains only message text,
with one message per line and a blank line between dialogues. On restart, the
script counts complete dialogues to resume at the next word. Omit `--limit`
to process the entire remaining list. Use a different `--output` directory
if the word list changes. Review the synthetic text before preparing it with
[the local SI corpus workflow](corpus/README.md).

#### Import unsegmented paragraphs

`corpus ingest` takes UTF-8 text with one paragraph per nonempty line. It
selects a complete segmentation by smoothed dictionary word frequencies,
so `没有输入法` can resolve to `没有 / 输入法` instead of greedily taking
`没有输`. Consecutive ASCII letters stay together. The same segmenter serves
user ingestion and preceding-field context. User counts provide a bounded
adjustment; previously saved counts and grams are not automatically rebuilt.
Only known words contribute lexical
counts. An unlisted run of at least two ASCII letters breaks the word-gram
sequence and goes to a separate CSV. An isolated ASCII letter contributes `<char>`
to n-grams, and an independent ASCII digit run such as `404` contributes
one `<num>`. The paired lexicon records their IDs as unindexed, zero-count
symbols. For ambiguous Han spellings, `pinyin_pro` reads the matched word
in isolation. The importer counts the existing dictionary entry whose
reading uniquely matches the result. Spaces preserve word adjacency.
Unknown symbols/text and still-unresolved spellings break the n-gram sequence
without creating a sentence boundary. Book-title marks, quotes and brackets
separate lexical matching while preserving word adjacency.

Base `corpus ingest` adds internal `<s>` and `</s>` tokens at the start and
end of each nonempty fragment delimited by `，,。！？!?；;：:…`, a sentence-final
ASCII period or a line ending. A period between ASCII letters/digits stays
inside the text, as in `3.14`, `example.com` and `Node.js`. Book-title marks,
quotes and brackets do not end a fragment: `看过《青蛇》吧？` supplies
`<s> 看过 / 青蛇 / 吧 </s>`, never `<s> 吧 </s>`. These wrappers separate
lexical matching without concatenating text or breaking word adjacency.
Other symbols break gram adjacency without creating a new start/end marker.
Splitting happens before word segmentation, even when a dictionary entry
contains wrappers or delimiters. For example, `我先自己试了一下，没搞定。` supplies two
separate sequences:
`<s> 我先自己试了一下 </s>` and `<s> 没搞定 </s>`, with the text between
markers segmented into words as usual. Spaces preserve adjacency; consecutive
punctuation and line endings do not create empty or duplicate boundaries.
Unknown English, unknown characters and unresolved readings still break
adjacency, but do not create artificial start/end markers beside the skipped
text. Boundary IDs are unindexed, zero-count symbols in the paired lexicon.
They contribute grams through the configured maximum order without adding
ordinary word counts. `user ingest` and pre-tokenized `corpus build`/`add`
do not add these markers. Conversion uses `<s>` for confirmed fragment starts;
`</s>` is not scored at candidate completion. Existing gram rows stay unchanged;
boundary counts require new
imports or a rebuild from the original corpus.

```sh
cargo run --release --locked -p si-cli -- corpus ingest Data/Engine/main.silex Data/Engine/words.sigram /path/to/paragraphs.txt
cargo run --release --locked -p si-cli -- corpus ingest Data/Engine/main.silex Data/Engine/words.sigram /path/to/more-paragraphs.txt
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
want to add, merge them into your English source CSVs, and build a fresh
lexicon with matching grams. The English entries use lookup index `1`.

The importer refreshes `words.sigram.review.csv` beside `words.sigram`
with unmatched characters and unresolved readings from the latest batch.
It includes occurrence counts, available readings, and the first source
file and line. Fill the final `reading` column with lowercase, toneless
Pinyin, using apostrophes between syllables. For an older review CSV, add
that column after `first_line`. Leave unconfirmed readings blank. Incorporate
reviewed readings into your Pinyin source CSVs, then build a fresh lexicon and
regenerate its word grams. `lexicon build` also accepts the seven-column
review format at index `0`: only completed rows contribute, repeated identities
sum, and no existing snapshot is modified. Old gram files must remain paired
with their original lexicon. A batch with no review items produces only the
header.

Every completed import adds its counts, even if the source was imported
previously. If an import is interrupted while publishing, rerun the same
command to finish publication without recounting the corpus.

Run `./scripts/si-corpus-clear-grams.sh` to delete
`Data/Engine/words.sigram`. The command preserves `main.silex`, the review
CSVs and the lock files. It waits for active writers and requires any pending
ingest publication to finish first. The next ingest starts with empty gram
counts and still adds word counts to `main.silex`.

#### Export and restore a lexicon

Run `./scripts/si-lexicon-export.sh` to export `Data/Engine/main.silex`
to `.build/si-data/main.silex.csv`. The export requires a new destination.

```sh
cargo run --release --locked -p si-cli -- lexicon export Data/Engine/main.silex .build/si-data/main.silex.csv
cargo run --release --locked -p si-cli -- lexicon export --language zh-Hans Data/Engine/main.silex .build/si-data/chinese.silex.csv
cargo run --release --locked -p si-cli -- lexicon restore .build/si-data/main.silex.csv .build/si-data/restored.silex
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
fresh `lexicon build` snapshots.

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
cargo run --release --locked -p si-cli -- lexicon build .build/si-data/learned.silex 0 /path/to/han-seed.csv
cargo run --release --locked -p si-cli -- corpus build --han .build/si-data/learned.silex .build/si-data/characters.sigram /path/to/corpus.txt
cargo run --release --locked -p si-cli -- --config config/si.conf lexicon learn .build/si-data/learned.silex .build/si-data/characters.sigram
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
any rows you do not want to add. Incorporate the reviewed entries into your
source CSVs and build a fresh dictionary with matching grams. There is no
CSV merge command for an existing snapshot. Already stored readings and word
IDs remain available through full snapshot export/restore.

Later exports use a fresh number so you can keep earlier edits. These
count and share thresholds can still admit common fragments, so corpus
coverage and word quality require separate evaluation.

## Model training experiments

The [conversion evals](eval/README.md) include 1,020 authored decoder recall
queries and 997 fixed-pool ranking queries, with both paired preceding-text
contrasts and context-free examples. Run `python3 scripts/evaluate_conversion.py check`
to verify the datasets. Recall reports preserve the full returned Rust pool.
Ranking reports score the frozen candidate text with the character LM. The
historical 220-query benchmark remains available for comparison.

The [model workspace](llm/README.md) contains offline Pinyin-to-text
training, small-model training, supplied-candidate scoring and inference
export. The [small reranker's chat preset](llm/reranker_small/README.md#chat-continued-pretraining)
prepares a dialogue-heavy dataset and initializes a new training run from the
existing character LM. The [local SI continuation](llm/reranker_small/README.md#continue-from-chat-v2-on-the-local-si-collection) prepares the selected SI TXT collection and initializes from the chat-v2 checkpoint. A larger reranker is planned.

The independent [corpus workspace](corpus/README.md) prepares pinned public Chinese conversation, web, Wikipedia and technical-documentation text, with per-source licenses, line origins and integrity reports. The complete-text extractor also accepts explicit local SI TXT and dialogue collections, including the eight-format Chinese Chatbot Corpus importer, converts extracted text with OpenCC t2s, and preserves repeated occurrences; its new outputs use `prepared/raw-text-v2`. Chinese Wikipedia acquisition resolves the latest complete official article dump and verifies its official checksum before recording the pin. It also exports explicit character/word readings from the maintained vocabulary. The separate [English conversation collection](corpus/english/README.md) acquires PersonaChat/ConvAI2, BST, Topical-Chat, Taskmaster 1/2/3, ABCD, SGD and English OASST1 messages, preserving dialogue/turn identity, data terms and upstream splits. Raw and prepared data stay local and outside Git. These preparation stages do not label sentence Pinyin, change existing training defaults or integrate a model into SI.

Git retains the application dictionary CSV sources, manifests, preparation/training code, configs, source pins, attribution, authored training CSVs and frozen regression fixtures. Generated databases, downloads, generated corpus tables, prepared datasets, Python environments and training outputs are ignored. See [the data policy](CONTRIBUTING.md#local-corpus-and-model-artifacts) and the corpus/model guides to recreate local artifacts; removing them from tracking preserves local copies and does not rewrite earlier Git history.

[The independent `llm/` framework](llm/README.md) defaults to a randomly initialized 19.7M Pinyin-to-Han encoder-decoder with explicit syllable sequences and optional preceding text. The [100,000-example dataset](llm/pinyin_to_text/data/syllable-csv/README.md) contains 96,000 training, 2,000 validation and 2,000 test rows derived from the maintained Chinese vocabulary. Data preparation checks syllable reconstruction and split separation, then freezes the CSVs and their provenance. Representative conversion quality and production segmentation need separate evaluation. Volunteered history exports have a separate [offline review workflow](docs/INPUT_HISTORY_EXPORT.md).

Each preset script performs one task: run `./llm/pinyin_to_text/scripts/setup.sh` for the environment, `./llm/pinyin_to_text/scripts/data.sh` for CSV preparation, `./llm/pinyin_to_text/scripts/run.sh` for small-model training on MPS, then separately run `validation.sh`, `test.sh`, `infer.sh` or `export.sh` as needed. Shared paths and parameters are in `llm/scripts/defaults.sh`; no stage launches the next one. The scripts use `llm/.venv` without activation and accept explicit argument overrides. Old environment overrides still take precedence; use a fresh terminal before using the new presets. Use `check.sh` and the tiny CPU `smoke.sh` for framework checks. See [the framework guide](llm/README.md) for preset locations and new-run/resume instructions.

A small [contextual smoke fixture](llm/pinyin_to_text/README.md#contextual-pinyin-experiment) exercises the same format and batched decoding.

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
