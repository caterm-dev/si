# SI

**One input. Every language.**

SI is an open-source macOS input method built around one idea: choose the languages you use in Settings or SI's input menu, then type without switching between language modes. Candidates from enabled languages appear together, including ambiguous matches. The original text always remains available.

> **Status: development preview; Chinese engine migration in progress.** The current worktree implements the Chinese decoder in Swift using MSIME-derived lookup and word-lattice algorithms, with a pinned dictionary maintained by SI. Debug and Release builds have passed. The remaining regression suite passes after ten failing tests were removed at the user's request; those underlying behaviors remain unresolved. See the current validation record. Chinese quality parity and host compatibility remain unproven. English lookup and bounded Chinese/English lexical paths are connected; full regressions and host verification remain incomplete.

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

The Chinese path queries exact full readings, syllable prefixes and initials, then constructs sentence candidates with a bounded word lattice. Lexical matches, generated sentences and completions compete by a shared score. Up to 32 complete minimum-syllable cuts share sentence search, so ambiguous boundaries such as `wo / xian / gan / zhao` and `wo / xiang / an / zhao` compete using dictionary frequency and spelling costs; `woxianganzhao` has `我想按照` as its leading complete sentence; prefixes compete separately by their own scores in the merged list. Apostrophes constrain syllable boundaries; prefix choices retain the exact unconsumed source spelling. SI deliberately lowers the extra single-character cost to let dictionary frequency compete more strongly with segmentation structure. The shared lexical cost is `20 - 1.05 × ln(weight)`, with an additional two nats for a single Chinese character or three nats for each English dictionary token (including lookup, completion and English/mixed sentence paths). The frequency coefficient strengthens dictionary-weight differences relative to insertion and spelling costs. These heuristic priors balance dictionary frequency against extra lexical splits; known ordinal ambiguities remain. The residual cost discourages excessive character splitting. This differs from the upstream scoring formula and does not establish MSIME-equivalent quality.

English word lookup and continuous English segmentation remain available. With both languages enabled, a bounded lexical lattice also joins complete Pinyin words and English words in either direction, including `woxiangyaodeploy` → `我想要 deploy`, preserved English casing, interleaved words and a completed final English word. Adjacent English words keep their word spaces inside mixed candidates too: `helloworldzhongwen` can offer `hello world 中文`. Chinese/English boundaries also insert one space; personal phrases and verbatim paths retain their exact concatenated output. It uses the same packaged dictionaries and relative weight unit; pure Chinese sentences retain their existing decoder. Exact English words and fully lexical English sentences keep their English identity. Chinese, English and mixed whole choices now compete by the same word, spelling and language-transition costs, with opted-in learning bonuses. Full Pinyin syllables and complete English words receive stronger spelling weight than incomplete observations: bilingual `ma` now leads with `吗`, while English completions remain available. This heuristic can favor fully spelled word sequences over an unfinished English word. No language category has a reserved front position. For `ling`, `零` scores above `里 NG`; English completions such as `lingo` remain eligible by score. See [candidate ranking](docs/UNIFIED_RANKING.md). Mixed initials, incomplete Chinese-tail prediction and broad language-boundary detection remain limited. The exact original input remains an explicit candidate, including unknown input and configurations with all languages disabled.

Whole candidates and prefixes compete using their lexical/preferences score plus five points per matched source letter or digit. Only the spelling a candidate consumes earns this presentation reward; output length, word count and the pending remainder do not. Apostrophes and punctuation earn no points, and ü/v/u: aliases count equally. Completions earn points only for typed spelling; candidates containing unrecognized verbatim spans receive no coverage reward. Base dictionary scores and learning caps are unchanged. Production ordering puts complete candidates before prefixes and longer prefix spans before shorter ones, subject to existing pins and remembered choices. Within a coverage group, candidates compete by score without estimating future conversions.

The window uses one 27-choice ordinary shortlist, including the exact original input, and additionally retains every generated Chinese dictionary character that the system font can display. Only the first four ranked choices may include constructed sentences or multiword fragments. Remaining ordinary slots are single-character/word choices, including exact prefixes, so sentence alternatives cannot fill later pages. Chinese, English and mixed hypotheses share the same four-choice eligibility without language reservations. Before shortlisting, the window excludes nonliteral candidates containing missing glyphs, including system LastResort placeholders; supported rare characters remain pageable. All retained nonliteral choices keep engine order, without language reservations, and the exact original input stays last. Prefix choices show a small arrow and consume only their exact source spelling: choosing `比如` from `biruzhege` leaves `zhege` editable. With `sheguofennudehai`, generated character choices remain pageable, allowing `涉` → `过` → `愤怒` → `的` → `海` to be selected individually. Tooltips and accessibility descriptions retain the exact consumed spelling. Return commits exact remaining spelling. Provisional hints may change when full results arrive. Live host compatibility remains unverified.

For `cichuxiande`, the single-character prefix `词` has the same lexical score as standalone `ci`, regardless of how `chuxiande` could convert. Choosing `词` leaves that exact remainder editable; the intended full sentence is not guaranteed as the first choice.

All input processing is local. SI has no analytics, keystroke logging, or cloud dependency for typing. Optional, user-initiated software update checks contact SI's download service without sending input or personal phrases. Language and learning settings are saved in UserDefaults. Personal Learning and Input History are independently off by default. Personal Learning retains aggregate preferences; Input History can retain each submitted spelling/text pair permanently on this Mac. Nothing is uploaded. See [personalization and privacy](docs/PRIVACY.md) for retained fields, retention, pause, deletion, and storage limitations.

Debug and Release use the same ranking. When a verified local KenLM model is
installed, SI scores Chinese words in the current composition, including
Chinese segments of mixed candidates. English uses dictionary scoring with its
own per-word insertion cost. SI reads no surrounding host-field text. The
model is installed separately and the dictionary supplies results while the
model is unavailable. See [production ranking and model installation](README_kenlm_train.md#production-kenlm-ranking).

## Input languages

The macOS input-source menu for SI includes independent **English** and **Chinese (Simplified)** checkmarks. Click either to enable or disable that input language without opening Settings. These global preferences stay synchronized with Settings and allow both languages together or neither (exact original input remains available). Changing a checkmark refreshes the active composition without committing its spelling or moving its caret. No keyboard shortcut is assigned. Per-application direct input still takes precedence; to convert Chinese in an app such as Terminal, first turn off its direct-input rule in Settings.

## Interface language

The app supports English and Simplified Chinese. Settings, input-menu actions, candidate descriptions and accessibility labels follow the macOS preferred app language, with English as the fallback. Set a preferred language for SI in **System Settings → General → Language & Region → Applications**, where available, then restart SI normally for the change to take effect. Do not launch a second copy of the input method.

Interface language is independent of the English/Chinese input-language switches. Changing it does not change candidates, committed text, personal phrases, learning consent or saved data. The compact E/C/A punctuation badges retain their existing identifiers; their full descriptions are localized.

## Vocabulary maintenance

Chinese and English base dictionaries now come from a pinned [rime-wanxiang-data](https://github.com/amzxyz/rime-wanxiang-data) revision. The independently written [conversion script](scripts/wanxiang_dictionary.py) imports `zi`, `jichu` and `duoyin` into `chinese/base.csv` (1,547,554 text/reading pairs), and `en` into `english/base.csv` (72,784 supported forms). Base weights retain the upstream integers, without wordfreq normalization or frequency rescaling, except for [documented SI editorial adjustments](Data/Vocabulary/chinese/README.md#si-editorial-weight-adjustments). The upstream weights are already transformed ranking values, not raw occurrence counts or probabilities. For `yuliao`, the SI editorial weight for `语料` is 2,500, placing it above `语聊` (2,442) and below `预料` (3,036) before personal preferences. This replacement changes vocabulary, casing and ranking; it does not establish improved conversion quality.

For `taiguo`, the editorial weight of 22,000 ranks `泰国` ahead of `太过`
(20,909) before personal preferences.

All ten other normal upstream Chinese dictionaries are imported into separate categories named after the upstream files, adding 602,516 category rows. With the reviewed corpus additions, the complete merged resources contain 2,141,468 Chinese and 74,341 English entries. The seven remaining local Chinese categories and the existing English movie/domain categories retain their text/readings with uniform weight 10. The separately removed culture/sports file is not restored. Their entries supplement the base; overlapping identities use the base weight and English casing, so historical category weights cannot overwrite the new source weights. Imported categories retain upstream weights over legacy category copies; duplicates within each tier still merge by maximum weight. Categories remain maintenance groups without language modes or ranking bonuses. The [domain category](Data/Vocabulary/DOMAINS.md) retains its 1,209 full hostnames and separate Radar CC BY-NC 4.0 terms; the [movie catalog](Data/Vocabulary/MOVIES.md) retains its 400 selected films from 2007–2026.

```sh
# Explicit source download, pinned by revision, size and SHA-256:
python3 scripts/wanxiang_dictionary.py fetch
# Offline replacement of both bases; preserves preexisting category CSVs:
python3 scripts/wanxiang_dictionary.py convert
python3 scripts/wanxiang_dictionary.py convert --check
# Compile the maintained CSV collection into shared package/app resources:
python3 scripts/csv_dictionary.py build
python3 scripts/csv_dictionary.py build --check
```

The [phrase and verse collection](Data/Vocabulary/chinese/phrase/README.md) separately
groups 46,497 clear base phrases and the existing 335,208-row poetry source.
The remaining word-side Chinese base has 1,501,057 rows. Compilation reads both
Chinese directories and preserves every effective entry, reading, weight and
deterministic order. Idioms, names, domain terms and ambiguous entries remain
conservatively grouped with words.

See the [import scope, exceptions and update workflow](Data/Vocabulary/Wanxiang/README.md). The conversion removes Chinese tones, maps ü to v and merges tone-collapsed duplicates by maximum weight. English retains SI's full-text typing-key contract rather than Rime abbreviations; case variants use the highest source weight with first-source ties. Nineteen unsupported non-ASCII English forms are listed in the conversion report. Missing weights remain zero; 73 malformed numeric suffixes use Rime's numeric-prefix interpretation. Neither the importer nor normal builds read private phrases or Personal Learning.

[Data/Vocabulary](Data/Vocabulary/README.md) contains the editable CSVs and source-level metadata. Normal CSV builds remain offline and do not rerun the upstream conversion. Both runtime databases retain the same SQLite schema and use the versioned `si-wanxiang-weight-v1` contract in `Data/DictionaryFormat.json`; incompatible old resources fail closed. Source pins, full data licensing, conversion checksums and preserved category hashes are retained. Older MSIME, SCOWL, CSpell, Rime Ice and wordfreq records remain historical attribution, not the current base-frequency pipeline. Historical Chinese MSNG tables remain archived outside the app and are not used for runtime scoring. See [Chinese maintenance](docs/CHINESE_VOCABULARY.md) and [English maintenance](docs/ENGLISH_VOCABULARY.md).

The SI-authored [English technology category](Data/Vocabulary/english/technology.csv) contains 164 common AI, software, hardware and networking terms at editorial weight 10. Existing base entries retain their weights and casing, including lowercase `ai`; typing `AI` still produces uppercase `AI`. See [technology maintenance](docs/ENGLISH_VOCABULARY.md#technology-category).

The [HanLP corpus review](Data/Vocabulary/Corpus/README.md) adds **266 reviewed Chinese terms** in the separate [corpus.csv](Data/Vocabulary/chinese/corpus.csv), with [counts/readings for inspection](Data/Vocabulary/Corpus/accepted.csv), and records eight bounded base-weight corrections. It processes all 34,445,051 Han characters in the six existing prepared subsets; these deduplicated observations are not general usage frequencies. New weights are explicit editorial values anchored to existing words, while all earlier local categories keep weight 10. Full source attribution accompanies the dictionary. HanLP is used only for offline analysis and is not included in the input method.

## Automatic prefix confirmation

Enable **Automatically confirm stable prefixes** in **SI Settings → Typing** to let SI confirm leading Chinese words while you continue typing or pause. It is off by default. SI keeps at least four output characters editable during continuous typing, or two after a pause of at least 1.8 seconds; complete-word boundaries can leave a longer ending. Only the confirmed source spelling is consumed, and the remaining exact spelling stays marked and editable without an extra space.

Automatic confirmation requires matching source/output boundaries across nearby full-search alternatives. Continued typing must also preserve the prefix across multiple results with additional input. A pause relaxes the ending length, but requires a prefix of at least two characters and does not override disagreement between candidates. Ambiguous input can remain entirely editable. Provisional hints never trigger confirmation. English/mixed leaders, uppercase/code-like spelling, personal phrases and unrecognized spans are excluded. These are conservative local heuristics, not a guarantee of sentence meaning or a way to predict whether later typing will turn a spelling into an identifier.

Editing, moving the caret, navigating/expanding candidates, or crossing a host boundary cancels automatic confirmation; fresh typing at the composition end starts new evidence. Settings changes, secure input, cancellation and stale asynchronous results cannot authorize a pending confirmation. Each pause can confirm at most once until more input arrives. Automatic confirmation does not train Personal Learning. If separately enabled, Input History records its submitted prefix like other SI commits. Return and shortcuts preserve only the remaining spelling once a prefix has been committed; editing already committed text uses the host application's normal editing tools. Native timer/focus behavior still requires the checks in [testing](docs/TESTING.md#automatic-prefix-confirmation).

## Direct input by application

Open **SI Settings → Direct Input by Application → Manage Direct Input…** and turn on direct input for apps such as Terminal. Every app uses normal SI conversion by default. The searchable list discovers apps in the standard system, local and user Applications folders, plus running apps, and displays each app's system icon beside its name. **Add Application…** lets you select an `.app` stored elsewhere; **Refresh** rescans the list. Rules are saved locally by bundle identifier, and enabled rules remain listed with a generic application icon when an app is no longer installed.

In a selected app, SI passes key events to the host without composition, candidates, punctuation conversion or automatic spacing. Space, Tab, Return, navigation and shortcuts belong to the host. If the rule takes effect during composition, SI inserts only the exact pending spelling once and rejects old candidate results and automatic-confirmation tasks. SI does not learn vocabulary while direct input is enabled; existing saved data remains until deleted. Turning direct input off restores ordinary conversion and the app's independently configured learning consent.

Rules use the InputMethodKit client's application identity, not the foreground process. A browser rule applies to every tab and input field; an editor rule includes its embedded terminal. It cannot distinguish an address from a search in a combined address bar. Application-wide rules need no Accessibility or Input Monitoring permission, and SI remains the selected system input source. Native host behavior still requires the [direct-input manual checks](docs/TESTING.md#direct-input-by-application).

## Experimental permissions

**SI Settings → Experimental Permissions** provides separate **Request Accessibility…** and **Request Screen Recording…** actions with current permission status. macOS controls authorization; denied requests open the corresponding Privacy & Security pane. Permission is requested only by these buttons, never automatically while typing. A restart of SI may be required after authorization; do not run built and installed copies together.

These permission entry points are available for future input-control experiments. They do not inspect controls, capture images or automatically select input behavior by field. Granting either permission leaves input behavior, enabled languages, Personal Learning and Input History unchanged. Input Monitoring and global event taps are not used. Native permission dialogs still require [manual verification](docs/TESTING.md#experimental-permissions).

## Personal Learning

Open **SI Settings → Personal Learning** and enable **Enable Personal Learning**. It is off by default. All eligible apps share one vocabulary and aggregate usage/correction counts. A deliberate selection of a nonfirst candidate makes it the first ordinary choice the next time the entire normalized source spelling matches. A later deliberate choice replaces that preference, including across languages. Explicit personal-phrase pins retain priority; other candidates and exact original input remain available. Case and ü/v/u: aliases use existing normalization, while explicit apostrophe boundaries remain distinct. Shorter spellings and longer compositions do not inherit this forced placement. Prefix confirmation records only consumed spelling, never the pending remainder.

Accepting the displayed first candidate by Space, number or mouse only updates usage; it does not increase ranking strength or change the remembered choice. Every three deliberate nonfirst selections also add one frequency-ranking point, up to 32, for whole/prefix and eligible internal-token ranking. This gradual bonus is separate from immediate exact-match placement. Neither strength nor records decay or expire with age. At most 5,000 entries are kept; capacity eviction removes the least recently used entries with deterministic identity ties. Confirming a sentence does not automatically save its component words. Literal, personal/verbatim, punctuation, delimiter and automatic-confirmation commits do not train vocabulary. Existing spelling/output size limits remain 128/512 bytes.

**Manage Learning Data…** supports global search, Forget and clearing learned vocabulary. Forgetting the remembered choice removes its forced placement; clearing does not affect explicit personal phrases. Personal Learning has one global switch, with no per-app pause, filter, deletion or clear controls. Turning learning off, secure input and the separate direct-input rules suppress learned ranking and saved suggestions. No document, URL, recipient or clipboard content is read.

The existing `SI/Personalization/application-memory-v1.json` path now uses vocabulary-only schema 4. On successful load, schemas 1–3 migrate atomically into one global vocabulary, dropping app identity and retired history. Identical spelling/language/output records combine bounded usage/correction counts, retain the latest usage/base metadata and use the maximum stored strength rather than adding strengths. Schema-1/2 ambiguous strengths/corrections are reset; schema-3 evidence is retained. Old archives have no deliberate-selection timestamp, so migration does not guess an immediate first choice. Retained old records are not discarded because of age; previously deleted/expired records cannot be recovered. Corrupt or unsupported archives remain untouched with a visible error, and failed migration writes pause loading. Existing learning consent is preserved. The retired per-app exclusion key is removed and no longer scopes learning.

The former App History completion/draft feature and previous-word pair learning remain removed. The new Input History below has separate consent and storage. The separate retired `SI/Personalization/preferences-v1.json` archive is never loaded, imported or used as a fallback; its old consent flags are ignored. **Delete Old Shared Learning Data…** still explicitly deletes that inactive archive and its consent flags without changing current vocabulary or personal phrases. External backups remain outside SI's deletion controls. Native host, Settings keyboard and VoiceOver verification remain separate [manual checks](docs/TESTING.md#app-vocabulary).

## Input History

Open **SI Settings → Input History** and enable **Save Input History**. It is independently off by default; enabling Personal Learning or a language does not enable history. Each successful SI composition submission keeps the exact consumed spelling, submitted text, timestamp, language/mixed identity and commit reason. Examples include `nihao` → `你好`, English conversion and original English/code committed with Return. SI-inserted spaces/punctuation are retained in the submitted output. Repeated submissions remain separate rows. Prefix selection and automatic confirmation each save only their submitted portion, leaving the pending remainder unrecorded until it is committed.

**History has no automatic expiry or record-count limit.** It stays on this Mac until you explicitly delete it. The 5,000-entry Personal Learning cap does not apply. History does not affect ranking, create completions or enter model training automatically. **View Input History…** offers spelling/text search and newest-first pages of up to 100 records, with individual Delete and **Clear Input History…**. Clearing learning/phrases/history affects only the chosen data category. Disabling history stops new recording while keeping saved records; accepted pending writes still finish.

History includes literal, personal-phrase, punctuation and automatic SI submissions when enabled. It does not capture cancelled compositions, raw keystrokes, document/clipboard text, standalone keys passed to the host outside composition or text in direct-input apps. Secure event input suppresses recording; it cannot detect every sensitive field. Recording is checked before and after the host insertion call, including consent generation changes during reentrant callbacks. Data is prospective: past input and retired history archives are not imported.

**Export Input History…** saves all persisted history as one versioned JSONL file, including records hidden by search. The action opens a save panel directly, with no backup/training distinction or purpose flag. Export never uploads or sends a file. It contains private source/output text and timestamps, and deleting local history does not delete exported copies. Accepted writes finish before export; pending save failures must be resolved first.

The receiver can run `python3 scripts/input_history.py inspect FILE.jsonl`, `restore FILE.jsonl --output NEW.sqlite3`, or `prepare FILE.jsonl --output NEW_DIRECTORY`. Restore validates versions/count/checksum and recreates every event exactly. Training preparation accepts the same export and produces an unsplit candidate CSV plus provenance for review, without modifying existing data or starting training. See [export/restore and training-observation workflow](docs/INPUT_HISTORY_EXPORT.md).

The independent owner-only SQLite database is `~/Library/Application Support/SI/InputHistory/history-v1.sqlite3`. It is not encrypted; private text can be accessible to other software running as you, administrators and backups. I/O stays off the main actor/key-event path. Writes are serialized and transactional, retries do not duplicate a submission, and clear cannot be undone by older pending writes. Open/save failures visibly pause recording; failed writes remain in memory for **Retry Saving History**, and corrupt/unsupported files remain untouched until explicit clear. Normal termination waits for queued writes; forced termination, disk failure or quitting without retry can lose unsaved entries. External backups remain outside SI's deletion controls. See [privacy](docs/PRIVACY.md#input-history) and [manual checks](docs/TESTING.md#input-history).

## Personal phrases

Open **SI Settings → Personal Phrases → Manage Personal Phrases…** to add a code such as `xm` and the exact text to insert. Choose its candidate language and optionally prefer it for a full-code match. Phrases work even with learning off, respect enabled languages, and remain until manually deleted. They are not copied into learning records or used as preceding-word context.

The manager supports search, editing, deletion, clear, and additive JSON import/export, with at most 1,000 phrases. Imports preserve existing phrases and pin settings; invalid or over-capacity imports leave the dictionary unchanged. Saved codes also participate in longer Pinyin/mixed paths: saving `xm` → `小明` lets `woaixm` offer `我爱小明`. Any path containing a personal phrase stays excluded from automatic learning and previous-word context. Exported files contain phrase text and must be handled as personal data. See [phrase format and controls](docs/USER_PHRASES.md).

## Requirements

- macOS 14 or later.
- Xcode 26 or later with Swift 6.2 or later and the macOS SDK.
- Git LFS for the maintained training CSVs. On macOS, install it with `brew install git-lfs` and run `git lfs install` before cloning.
- Xcode resolves the pinned Sparkle 2.10.0 update framework on the first app build; no Apple Developer account is needed for an unsigned development build. Chinese vocabulary comes from pinned MSIME sources and context artifacts. English retains attributed SCOWL, CSpell and Rime Ice selections, with wordfreq frequency data.
- Xcode resolves the pinned Sparkle 2.10.0 update framework on the first app build; no Apple Developer account is needed for an unsigned development build. Chinese context artifacts remain pinned to MSIME. Both base vocabularies come from Wanxiang; historical category data retains attributed SCOWL, CSpell and Rime Ice selections, with wordfreq frequency data.

## Get started

```sh
git clone https://github.com/caterm-dev/si.git
cd si
git lfs pull
# Generate the ignored runtime databases offline from the tracked vocabulary CSVs:
python3 scripts/csv_dictionary.py build
./scripts/test.sh
./scripts/build.sh
```

The application is built at `.build/xcode/Build/Products/Debug/SI.app`.

Training CSVs under `llm/pinyin_to_text/data/csv/` are stored with Git LFS. For an existing clone, install Git LFS, run `git lfs install --local`, then `git lfs pull` to download the CSV contents. See [the data guide](llm/pinyin_to_text/data/csv/README.md) before preparing a dataset.
Generated `.db`, `.sqlite` and `.sqlite3` files and SQLite sidecars are Git-ignored.
Run `python3 scripts/csv_dictionary.py build` before the first build/test in a fresh
clone and after vocabulary edits. This compiles both dictionaries offline from
tracked CSV sources; manifests and attribution remain in Git. The app and package
use these same local files. Build/test scripts do not generate databases or acquire
corpora, and require no language-model staging or training.

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
eval/                  Shared frozen ranking, correction and Pinyin-to-Hanzi evaluation
corpus/                Pinned offline Chinese text, English dialogue and lexical reading resources
llm/                   Offline spelling-to-text training experiments (not loaded by the app)
```

The Swift package and Xcode app compile the same core source files. There is no separate copy of the engine to keep in sync.

## Model training experiments

The [shared evaluation registry](eval/README.md) owns fixed datasets for ranking,
correction and Pinyin-to-Hanzi conversion, independent of model size or algorithm.
It provides blind input export, a common prediction format, exact-output scoring,
integrity/split checks and comparable reports. Small and future large rerankers
use the same frozen ranking pools; model-specific training/loss evaluation stays
under `llm/`. Run `python3 -m eval validate` to inspect the registered suites.

The [model workspace](llm/README.md) separates `reranker_small/`, `reranker_large/` and `pinyin_to_text/`. The [small reranker](llm/reranker_small/README.md) supports training a 7.4M character LM from scratch, whole-document preparation, candidate scoring/evaluation and inference export. Its [constructed Chinese challenge](llm/reranker_small/benchmarks/README.md) contains 1,230 cases from 337 anchors, with real decoder pools and separate development/test splits. Independent annotation review remains pending; native neural ranking has been removed pending redesign; the large reranker is planned. The existing conversion framework, data, configs, runs and reports are under `llm/pinyin_to_text/`; the shared Python environment stays at `llm/.venv`.

The independent [corpus workspace](corpus/README.md) prepares pinned public Chinese conversation, web, Wikipedia and technical-documentation text, with per-source licenses, line origins, deduplication and integrity reports. Chinese Wikipedia acquisition resolves the latest complete official article dump and verifies its official checksum before recording the pin. It also exports explicit character/word readings from the maintained vocabulary. The separate [English conversation collection](corpus/english/README.md) acquires PersonaChat/ConvAI2, BST, Topical-Chat, Taskmaster 1/2/3, ABCD, SGD and English OASST1 messages, preserving dialogue/turn identity, data terms and upstream splits. Raw and prepared data stay local and outside Git. These preparation stages do not label sentence Pinyin, change existing training defaults or integrate a model into SI.

Git retains the application dictionary CSV sources, manifests, preparation/training code, configs, source pins, attribution, authored training CSVs and frozen regression fixtures. Generated databases, downloads, generated corpus tables, prepared datasets, Python environments and training outputs are ignored. See [the data policy](CONTRIBUTING.md#local-corpus-and-model-artifacts) and the corpus/model guides to recreate local artifacts; removing them from tracking preserves local copies and does not rewrite earlier Git history.

[The independent `llm/` framework](llm/README.md) now defaults to a randomly initialized 19.7M encoder-decoder for Pinyin-to-Han characters and short words. Its [focused static CSVs](llm/pinyin_to_text/data/pinyin-csv/README.md) use explicit `train/`, `validation/` and `test/` directories with `characters.csv` and `words.csv` groups. Preparation freezes maintained rows and source hashes without generating sentences, Pinyin, typos or random splits. This experiment excludes sentence templates, English/mixed and typo sources; those earlier experiments remain available separately. Representative converter quality and native converter deployment remain unverified; native neural ranking has been removed pending redesign. Default model sources exclude live Personal Learning, personal phrases, Input History and retired archives. Explicitly volunteered history exports can separately become reviewed offline training observations through [the export workflow](docs/INPUT_HISTORY_EXPORT.md); no live collection or automatic training is connected.

Each preset script performs one task: run `./llm/pinyin_to_text/scripts/setup.sh` for the environment, `./llm/pinyin_to_text/scripts/data.sh` for CSV preparation, `./llm/pinyin_to_text/scripts/run.sh` for small-model training on MPS, then separately run `validation.sh`, `test.sh`, `infer.sh` or `export.sh` as needed. Shared paths and parameters are in `llm/scripts/defaults.sh`; no stage launches the next one. The scripts use `llm/.venv` without activation and accept explicit argument overrides. Old environment overrides still take precedence; use a fresh terminal before using the new presets. Use `check.sh` and the tiny CPU `smoke.sh` for framework checks. See [the framework guide](llm/README.md) for preset locations and new-run/resume instructions.

An [MPS dropout/checkpoint gradient correction](llm/README.md#mps-checkpointdropout-correction) fixes accelerator RNG replay during training recomputation. Earlier affected weights are preserved for inference; the correction requires a new experiment and does not establish conversion quality.

The focused collection initially has 2,021 training pairs (937 character/readings and 1,084 short words), 73 validation and 69 test pairs. Its audit records the one-time vocabulary selection and training-only character alignment. This is limited coverage and does not establish held-out word quality. The earlier [50,000-sample collection](llm/pinyin_to_text/data/csv/EXPANSION_50K.md), 0.403B config, prepared snapshots and checkpoints remain unchanged for explicit use; old weights do not resume into the smaller architecture.

## Website

The static website supports English and Simplified Chinese, with dedicated Privacy and Terms pages and an accessible scripted input demonstration. It highlights offline, on-device typing while explaining the separate user-initiated update connection and independently opted-in local data. Its download section offers separate Apple Silicon (arm64) and Intel (x86_64) images from the published R2 channels, each with its matching checksum and source archive. Build it with `node scripts/build-website.mjs`; see [website development and GitHub Pages deployment](docs/WEBSITE.md) for preview, localization, download updates, and custom-domain setup.

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) and the [architecture](docs/ARCHITECTURE.md). Keep code, source localization keys, documentation, issue reports, and pull requests in English. App translations, language data and user input retain their original scripts.

See the [roadmap](docs/ROADMAP.md) for planned work and [manual verification](docs/TESTING.md) for host-app checks. Run core tests and macOS builds locally; GitHub Actions retains only the website workflow.

The `./scripts/benchmark.sh` harness covers synthetic Chinese/mixed scenarios, including `woxiangyaodeploy`, saved preferences and personal phrases, English lookup, and synchronous/deferred edit costs. It has been run for the mixed lexical integration; initialization is lazy on candidate workers and older timing figures do not describe this version. Benchmark scenarios and quality fixtures still need reconciliation with the new policy. See [dictionary provenance and decoder limits](docs/DICTIONARIES.md), [the MSIME algorithm study](docs/MSIME_ALGORITHM.md), and [verification status](docs/VERIFICATION.md).

## License

SI is licensed under the GNU General Public License, version 3. See [LICENSE](LICENSE). The repository's existing license is preserved. The vocabularies include SCOWL, MIT-licensed CSpell lists and selected Rime Ice data; wordfreq-derived frequency data retains CC-BY-SA-4.0 attribution and redistribution terms. See [data provenance](docs/DICTIONARIES.md). Additional dictionaries or language models must have compatible licenses and documented provenance.
