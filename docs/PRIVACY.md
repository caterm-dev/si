# Personal data and privacy

SI processes input locally with no analytics, raw-keystroke logger, or cloud dependency for typing. Independently opted-in Input History can retain each SI submission locally as described below. User-initiated software updates are the only app network feature.

## Model experiments

The input method uses dictionary-frequency and opted-in Personal Learning ranking.
It loads no AI model and reads no preceding input-field text. The former AI ranking
and context switches are removed, and their saved preferences are cleared without
changing language, Personal Learning or Input History consent. Offline model
experiments remain separate from typing.

## Software update requests

**Check for Updates…** uses Sparkle 2.10.0 to request SI's public HTTPS appcast on `downloads.caterm.com`, followed by an update archive only when the user chooses to download/install. Automatic checks, automatic installation, and system-profile submission are disabled. Requests expose ordinary connection metadata, including the IP address and HTTP user agent (which may identify app/framework/OS versions), to the download service. They do not include composition text, committed text, host-document text, personal phrases, learned preferences, or chronological typing history. The updater has no reference to input sessions or personal-data models.

Sparkle retains its ordinary updater preferences and last-check information in the app's bundle defaults domain (`com.caterm.inputmethod.si`) and may cache update downloads. This is separate from language/learning consent and private phrase/learning archives. No vocabulary is downloaded while typing. Closing Settings keeps the input server alive; choosing to install an update restarts SI after its normal pending-write flush. A log out/back in may still be needed if macOS does not resume the input method.

## Experimental permissions

**Experimental Permissions** offers separate, user-initiated Accessibility and Screen Recording permission requests. These grants are independent of input languages, Personal Learning and Input History, and do not change input behavior. Startup and typing never prompt for permission. Revocation is available in macOS Privacy & Security.

The permission entry points do not inspect focused controls, read field values or URLs, capture images or perform OCR. There are no focus observers or field-based automatic input rules. Neither permission enables network transfer, Input Monitoring, global event taps or additional retained input data.

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
