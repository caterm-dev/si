# Personal data and privacy

SI processes ordinary input locally, with no analytics or raw-keystroke logging. Independently opted-in Input History can retain each SI submission locally. Network features are user-initiated software updates and separately opted-in AI completion.

## Local language model

When a verified KenLM model is installed, the input method scores Chinese
candidate tokens locally during the current composition. It reads no text
from the host field or earlier submissions for ranking. It does not query
KenLM during secure event input. The LM adds no persistent storage or cross-composition state and makes no network requests. Personal Learning and
Input History retain their independent consent and storage rules.

## Software update requests

**Check for Updates…** uses Sparkle 2.10.0 to request SI's public HTTPS appcast on `downloads.caterm.com`, followed by an update archive only when the user chooses to download/install. Automatic checks, automatic installation, and system-profile submission are disabled. Requests expose ordinary connection metadata, including the IP address and HTTP user agent (which may identify app/framework/OS versions), to the download service. They do not include composition text, committed text, host-document text, personal phrases, learned preferences, or chronological typing history. The updater has no reference to input sessions or personal-data models.

Sparkle retains its ordinary updater preferences and last-check information in the app's bundle defaults domain (`com.caterm.inputmethod.si`) and may cache update downloads. This is separate from language/learning consent and private phrase/learning archives. No vocabulary is downloaded while typing. Closing Settings keeps the input server alive; choosing to install an update restarts SI after its normal pending-write flush. A log out/back in may still be needed if macOS does not resume the input method.

## Experimental permissions

**Experimental Permissions** provides separate buttons for the Accessibility and Screen Recording panes in macOS Privacy & Security. The floating panel offers the running SI bundle for the user to drag into the system permission list. The operating system handles grants and revocation. These grants are independent of input languages, Personal Learning, Input History and AI completion consent. Startup and typing never prompt for permission.

PermissionFlow uses the System Settings window position to place its floating panel. The permission entry points do not inspect focused controls, read field values or URLs, capture images or perform OCR. System permission alone does not enable network transfer, Input Monitoring, global event taps or retained input data.

## AI completion

**Enable AI Completion** defaults to off. Enabling it authorizes manual requests in all apps where SI conversion is active; there is no AI app allowlist. Existing AX completion consent is reset for this screenshot-based feature. Screen Recording authorization is required. On a plain Tab during composition, SI can send current spelling, a whole candidate, available verified IMK text within 1,024 UTF-16 units of each side, and a screenshot of only the current input app's foreground window. A second Tab or click accepts the displayed result. Ordinary typing never starts AI work.

Screenshots may include private messages and other content elsewhere in that window. SI checks secure event input, direct input, client, foreground app and window boundaries around capture and delayed work. Secure event input cannot identify every sensitive field. No AX tree or clipboard content is collected. macOS permission alone never enables AI requests; the AI switch and explicit Tab are both required.

SI keeps screenshot bytes and context transient. Claude Code receives an in-memory base64 image via stdin. OpenAI receives an HTTPS image data URL with `store: false`. Codex requires an owner-only temporary PNG, removed after normal completion or cancellation; forced termination or cleanup failure can leave it in the OS temporary directory. The selected provider applies its own network and retention policies. CLI session persistence is disabled. API keys are stored in Keychain and can be removed in Settings.

Edits and app/window changes invalidate suggestions. Provider, path and key changes disable completion until re-enabled. If Input History is independently enabled, accepted submissions can be retained locally; screenshots and context are not stored in Input History. AI suggestions do not train Personal Learning.

## Personal Learning

**Enable Personal Learning** in **Personal Learning** defaults to off. Eligible apps share one local vocabulary. There are no per-app learning controls. The separate direct-input feature uses the IMK client's bundle identifier and stops all conversion and learning in selected apps; browser tabs share that direct-input rule. Personal Learning does not read documents, clipboard, window titles, URLs or chat recipients. Optional experimental permissions are described below; SI uses no Input Monitoring permission or global event tap.

Each record retains normalized consumed spelling, exact output/language/mixed identity, bounded strength, aggregate usage/nonfirst-choice counts, base score, lexical-unit evidence and last-use time. The currently remembered deliberate choice for a spelling also retains its selection time. A new deliberate nonfirst choice replaces the prior selection marker for that spelling; no chronological sequence is saved by Personal Learning. App identifiers are no longer stored in vocabulary rows. First-choice Space/number/mouse acceptance only updates usage, never preference strength or the selection marker. Every three nonfirst choices add one frequency point up to 32. Separately, one deliberate selection is enough to lead the next exact normalized-spelling search, after any explicit personal-phrase pin. Prefixes save only consumed spelling. Literal, personal/verbatim, punctuation, delimiter and automatic confirmations are excluded, and confirmed sentences do not create additional component-word records.

**There is no age expiry or strength decay.** Records remain until Forget, clear or capacity eviction; a maximum of 5,000 global records is retained, removing the least recently used entries first with deterministic identity ties when full. This longer retention applies to existing records still present at migration, but cannot restore previously removed data. Personal Learning does not create input history; the separately opted-in Input History feature below has its own retention and deletion. There is no synchronization, learning export/import or remote aggregation.

**Manage Learning Data…** provides global vocabulary search, Forget and clear. Forgetting or clearing immediately invalidates learned ranking and exact-choice placement, including pending candidates; older queued saves cannot undo a newer deletion. Clearing learning leaves Input History, explicit phrases and the retired shared archive alone. Disabling Personal Learning, secure input and disabled-language filtering suppress both saved candidates and token/whole learning effects. Enabled languages never grant recording consent. Preview never records.

The archive remains at:

```text
~/Library/Application Support/SI/Personalization/application-memory-v1.json
```

New writes use vocabulary-only schema 4. The archive has a 64 MiB limit, owner-only directory/file permissions and atomic replacement. SI does not encrypt it; software under the same user, administrators or backups may access it. Saves run off the main actor, coalesce for 300 ms and flush at normal termination; forced termination can lose recent updates. Open/migration errors pause recording and learned suggestions; save/erase errors appear in Settings. Learning consent remains in UserDefaults. The retired per-app learning exclusion key is removed. No personal data is supplied to Sparkle or another network service.

## Input History

**Save Input History** in **Input History** has independent `inputHistory.enabled` consent and defaults to off. Language, Personal Learning and retired history settings do not enable it. When on, each successful SI submission saves a new UUID, exact consumed spelling, exact submitted output (including SI-inserted suffixes), timestamp, optional language/mixed identity and commit reason. Repeat submissions stay separate. Literal English/code, personal phrases, punctuation and automatic confirmations are included. Prefixes save only their committed spelling/output; the pending suffix stays unrecorded until committed. This is a record of SI submissions, without document readback or monitoring raw key events.

**Records are retained indefinitely with no age or count eviction**, separate from Personal Learning's 5,000-entry cap. History grows with use and available disk space. **View Input History…** supports literal spelling/text search and newest-first pages of up to 100 entries, individual Delete and **Clear Input History…**. Turning history off stops new recording but keeps saved records and lets already accepted writes finish. History deletion/clear leaves learning/phrases alone; learning/phrase deletion does not remove separately recorded history copies. Clear also discards pending failed-write records. No prior input or retired history archive is imported.

History is stored at:

```text
~/Library/Application Support/SI/InputHistory/history-v1.sqlite3
```

The system SQLite database uses schema 1, a 0700 directory, 0600 file and DELETE journaling. It is not encrypted; software running as you, administrators and backups may access private text. Parameterized SQL preserves exact UTF-8 input/output and never includes that text in diagnostic messages. Actor-isolated transactional writes and bounded pages avoid main-actor I/O and loading the entire history. Stable event IDs avoid retry duplicates. Clear is ordered after in-flight writes, rejects obsolete queued records and removes the database/sidecars; ordinary deletion does not provide a forensic/backup erasure guarantee.

Recording is checked around host insertion, with generation checks for off/on changes during callbacks. Secure event input and the independent direct-input app rules suppress recording. Secure event input cannot detect every sensitive field. Cancelled/unconfirmed compositions, host documents/clipboard, standalone passthrough keys, other input sources and text typed in direct-input apps are not captured. There is no global event tap or added permission. Records are not used for candidates, automatic learning/training or remote services. Explicit export and separately permitted offline training preparation are described below.

Open/save failures visibly pause new recording. Failed accepted writes remain in memory for explicit **Retry Saving History**; **Reopen History** retries opening, and explicit clear can recover corrupt/unsupported data. Existing corrupt/unsupported bytes remain untouched until clear. Normal termination waits for queued writes; forced termination, disk failure or quitting with unretried errors may lose unsaved records. External backups and previously deleted filesystem remnants remain outside SI's deletion controls.

## Sentence History

**Save Complete Sentences** is a separate, default-off opt-in. Enabling it allows capture in all apps where SI conversion is active, without an app allowlist. On Return after a successful SI insertion in the same active client, with the composition empty and the caret at the end, SI can request at most 1,024 UTF-16 units from the current InputMethodKit text client. InputMethodKit does not expose the field's role, and Secure Event Input cannot identify every sensitive field. The exact single-line text returned by the client may include pre-existing or pasted content, other edits and punctuation inserted by the host. SI checks secure input, direct input, consent and the client boundary before and between calls, and skips unsupported or incomplete reads. This feature uses the text client directly, without accessing the clipboard or requesting additional permissions.

The independent owner-only, unencrypted `SI/SentenceHistory/sentences-v1.sqlite3` under Application Support retains the exact text, timestamp and event UUID until deleted. Application bundle identifiers are not stored in sentence records. The retired app allowlist setting is removed without changing recording consent. Turning off recording stops future capture and keeps earlier records. Search, per-entry deletion, clear, retry and the normal termination flush follow the same storage rules as Input History. **Export Saved Sentences…** writes all saved sentences and timestamps to one user-selected JSONL file. Exports are unencrypted and stay outside local deletion controls.

## User-controlled history export and training contributions

**Export Input History…** opens a save panel directly and exports all saved records, including private text, personal-phrase copies and timestamps, as one unencrypted JSONL file at a user-selected destination. There is one export, without backup/training choices, training-permission fields or a receiver-tool purpose gate. Exporting does not change recording consent or send/upload anything. The owner decides whether/how to share it.

The export streams a consistent snapshot, preserves repeats and exact source/output data, and includes version, record-count and SHA-256 checks. Accepted queued writes finish first; unresolved failed saves prevent incomplete export. The receiver's offline tool can restore the exact native SQLite records or prepare unreviewed candidate CSV/provenance from the same file. It does not auto-train, edit maintained sources or declare redistribution rights. A checksum detects corruption, not forgery.

Exports use 0600 file permissions and atomic replacement. SI's clear/delete controls cannot delete exported files, backups or files already sent to someone else. Training contributions must be reviewed for private/unsuitable material, provenance and evaluation leakage before any explicit model training. Received exports and derived candidates are kept outside Git/public datasets; nothing is uploaded by the app or helper. See [format and receiver commands](INPUT_HISTORY_EXPORT.md).

## Older archives and retired features

On successful load, schema-1/2/3 app archives migrate atomically to global schema 4, dropping application identifiers and retired history fields. Equal spelling/language/output rows merge bounded usage/correction counts, use the latest usage/base metadata and retain the maximum stored strength without adding app bonuses. Schema-1/2 strengths/corrections are reset because they mixed default acceptance and deliberate corrections; schema-3 evidence is preserved. Old archives lack deliberate-selection times, so migration does not invent a first-choice override. Existing learning consent remains intact; old history consent/exclusion keys are discarded and cannot enable learning. Corrupt/unsupported files remain untouched; migration write errors pause loading. External backups and forensic remnants of previous files are outside SI's deletion controls.

The former App History completion/draft feature, Return-delimited passthrough units and previous-word pair learning remain removed. New Input History does not load those archives or reuse their consent. The former shared **Personal learning** feature's archive is separate:

```text
~/Library/Application Support/SI/Personalization/preferences-v1.json
```

That file is never opened for ranking, imported, updated, expired or automatically deleted. Old `personalization.enabled` and `personalization.contextEnabled` flags cannot enable current learning. **Delete Old Shared Learning Data…** checks existence without decoding, then explicitly deletes only that inactive archive and its flags, with independent progress/error feedback. Current global vocabulary uses the app archive's migration and consent, rather than restoring this retired feature or its data.

## Explicit personal phrases

The separate [personal phrase dictionary](USER_PHRASES.md) retains user-entered codes, output text, language, pin setting, and stable identifiers. It is available with learning off, stores up to 1,000 phrases without automatic expiry, and supports edit, individual deletion, clear, and explicit JSON import/export. Personal phrases are not duplicated into automatic learning records or used as preceding-word context. Clearing learning and clearing the dictionary are separate actions; exported files and external backups are outside either clear operation.

There is no app-vocabulary export/import, synchronization, remote aggregation or automatic document harvesting.


## Ranking and safeguards

Global frequency rewards affect whole/prefix and eligible token ranking with a shared 32-point cap and no decay. Chinese single-character preferences remain limited to their own spelling; English words and Chinese words of at least two characters can influence matching internal tokens. Token/whole bonuses use their maximum rather than adding twice. Immediate last-choice placement requires the whole normalized spelling and does not add unbounded score or leak into pending suffixes. Personal-phrase pins keep their explicit contract. Personal/verbatim paths receive no automatic-learning bonus. Secure event input suppresses all automatic learning and learned suggestions; it is a conservative process-wide check, not a detector for every sensitive field. Disabling learning, deletion and clear also stop token effects. Existing core contextual APIs remain library fixtures and do not enable previous-word product learning.
