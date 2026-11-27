# Personal data and privacy

SI processes ordinary input locally, with no analytics or raw-keystroke logging. Independently opted-in Input History can retain each SI submission locally. Network features are user-initiated software updates and separately opted-in AI completion.

## Local candidate ranking

The Rust decoder scores the current composition with bundled dictionary
counts, word grams and eligible local preferences. For ordinary ranking, SI
asks the active InputMethodKit client for the complete text before the insertion
point at composition start and after a prefix commit. Rust uses the last
sentence for its local word-gram score. Secure input and direct input skip this
read. Unsupported clients fall back to ranking without field text. This read
requires no additional system permission. The text and score adjustment stay in
memory for conversion and are never logged, saved, sent to a service or used as
training data by this path. AI Completion has separate
triggers and data flows described below.

On Space, number or mouse confirmation, SI may also request at most four UTF-16
units before the marked spelling to separate Chinese and English at the insertion
boundary. A valid reported marked range needs only this prefix read; if the range
must be derived from the document caret, SI also validates the displayed spelling.
A native response may cover more text than requested; SI keeps only the requested
slice and discards the rest. Host ranges and client state are revalidated, and
secure/direct input skips reads. Boundary snippets stay transient and are not
logged, recorded, used for learning or sent to a service. Independently enabled
Input History records only the actual submission, including a leading space SI adds.

The optional Local model ranking switch also uses a short suffix of the
already available preceding text and a bounded pool of current candidates.
Its on-device scores and inputs stay transient. Secure and direct input skip
inference. The switch grants no recording consent or network access.

## Software update requests

**Check for Updates…** uses Sparkle 2.10.0 to request SI's public HTTPS appcast on `downloads.caterm.com`, followed by an update archive only when the user chooses to download/install. Automatic checks, automatic installation, and system-profile submission are disabled. Requests expose ordinary connection metadata, including the IP address and HTTP user agent (which may identify app/framework/OS versions), to the download service. They do not include composition text, committed text, host-document text, personal phrases, learned preferences, or chronological typing history. The updater has no reference to input sessions or personal-data models.

Sparkle retains its ordinary updater preferences and last-check information in the app's bundle defaults domain (`com.caterm.inputmethod.si`) and may cache update downloads. This is separate from language/learning consent and private phrase/learning archives. No vocabulary is downloaded while typing. Closing Settings keeps the input server alive; choosing to install an update restarts SI after its normal pending-write flush. A log out/back in may still be needed if macOS does not resume the input method.

## Experimental permissions

**Experimental Permissions** provides separate buttons for the Accessibility and Screen Recording panes in macOS Privacy & Security. The floating panel offers the running SI bundle for the user to drag into the system permission list. The operating system handles grants and revocation. These grants are independent of input languages, Personal Learning, Input History and AI completion consent. Startup and typing never prompt for permission.

PermissionFlow uses the System Settings window position to place its floating panel. The permission entry points do not inspect focused controls, read field values or URLs, capture images or perform OCR. System permission alone does not enable network transfer, Input Monitoring, global event taps or retained input data.

**Export Current App AX Data…** in SI's input menu explicitly saves one local inspection of the foreground application's accessible elements. This can include private document text, messages, labels and URLs across the application's exposed windows, beyond the current input field. It requires an existing Accessibility grant, aborts on secure input or changed foreground identity and redacts secure text nodes; this cannot detect every sensitive field. The bounded JSON includes read errors and truncation metadata, so it is not guaranteed to contain the complete application. SI does not invoke actions or parameterized attributes. The owner-only files are stored in `~/Library/Application Support/SI/AXExports/` and revealed in Finder. They are unencrypted, never sent to AI or used for learning/history, and retained until you delete them in Finder. Other software running as you, administrators and backups may access them. Ordinary typing and granting permission do not create exports.

The optional offline `scripts/ax_to_text.py` tool reads only a selected existing snapshot and writes only owner-only sentence TXT files. These can contain the same private text as the original export, including exposed offscreen content. Outputs default to the snapshot directory, remain until manual deletion and have no automatic learning, upload or network use. Default `SI-AX-*` output names are ignored by Git; use a private directory for custom names.

## AI completion

**Enable AI Completion** defaults to off. Enabling it authorizes manual requests in all apps where SI conversion is active; there is no AI app allowlist. Existing AX completion consent is reset for this screenshot-based feature. Screen Recording authorization is required. On a plain Tab during composition, SI can send current spelling, a whole candidate, available verified IMK text within 1,024 UTF-16 units of each side, and a screenshot of only the current input app's foreground window. A second Tab or click accepts the displayed result. Ordinary typing never starts AI work.

Screenshots may include private messages and other content elsewhere in that window. SI checks secure event input, direct input, client, foreground app and window boundaries around capture and delayed work. Secure event input cannot identify every sensitive field. The AI path collects no AX tree or clipboard content. macOS permission alone never enables AI requests; the AI switch and explicit Tab are both required.

SI keeps screenshot bytes and context transient. Claude Code receives an in-memory base64 image via stdin. OpenAI receives an HTTPS image data URL with `store: false`. Codex requires an owner-only temporary PNG, removed after normal completion or cancellation; forced termination or cleanup failure can leave it in the OS temporary directory. The selected provider applies its own network and retention policies. CLI session persistence is disabled. API keys are stored in Keychain and can be removed in Settings.

Edits and app/window changes invalidate suggestions. Provider, path and key changes disable completion until re-enabled. If Input History is independently enabled, accepted submissions can be retained locally; screenshots and context are not stored in Input History. Accepting a suggestion does not trigger learning.

## App Learning

**Enable App Learning** is an independent default-off consent under **Personal Data**. When enabled with Accessibility trust, SI attempts one background AX read of the eligible foreground input app's focused window every 30 seconds. The IMK client's app identity must match the foreground process. SI itself, direct-input apps and secure input are skipped; focused secure fields abort capture. Button/menu/toolbar/image subtrees, declared hidden elements and other secure fields are excluded. Accessible offscreen text can be included, and AX cannot identify every sensitive field. Complete-snapshot and state checks reject unavailable, truncated or obsolete captures. No clipboard, screenshot, AI request, network call or raw-keystroke recording is involved. Granting Accessibility alone never enables this feature.

Each app retains only its previous accepted paragraph snapshot in memory; window/document identities are not retained for deduplication. Snapshot source text defaults to a 512-KiB limit in UTF-8; larger snapshots are skipped without replacing the previous snapshot. Each app’s fixed model files default to a combined 64-MiB limit, with no separate paragraph/word/gram/app-count quotas. Both byte limits and the maximum word-gram order (default four) come from `[app]` in the build-time embedded `config/si.conf`; configuration changes require rebuilding/reinstalling SI. Per-app derived words, word-gram counts and metadata (bundle ID, version/revision, update time and counts) persist in owner-only, unencrypted `SI/AppLearning/<SHA-256-of-bundle-ID>/` directories in Application Support. These models are not connected to candidate search, global learning or Input History. Derived vocabulary can contain private names, addresses or other words from the source. Other same-user software, administrators and backups may access the files. Models remain until the page's per-app Delete or Clear All action; the fixed model files, metadata and any interrupted temporary publication are deleted, and older captures cannot recreate them. External backups are outside SI's deletion controls. Turning the switch off stops reads and releases transient session text after in-flight work finishes, retaining saved derived files. Normal termination waits for accepted work. Failed snapshots are not durably queued; errors pause sampling and Retry resumes it.

Deduplication compares exact paragraph occurrence counts with only the immediately preceding app snapshot. Edits append new observations; old statistics are not retracted. There are no per-window/document states or older snapshot histories. Text absent from the preceding sample can count again when it returns; restart/off clears the previous snapshot. A complete empty snapshot clears it, while incomplete reads are skipped. No cross-document or cross-restart deduplication is promised. No existing learning/history flag enables App Learning and no retired app archive is migrated. See [implementation and limits](ARCHITECTURE.md#app-learning).

## Personal Learning

**Enable Personal Learning** in **Personal Learning** defaults to off. Eligible apps share one local vocabulary. There are no per-app learning controls. The separate direct-input feature uses the IMK client's bundle identifier and stops all conversion and learning in selected apps; browser tabs share that direct-input rule. Personal Learning uses confirmed candidate choices. The default local user model also learns from spelling submitted with Return during composition. Optional experimental permissions are described below; SI uses no Input Monitoring permission or global event tap.

Each record retains normalized consumed spelling, exact output/language/mixed identity, bounded strength, aggregate usage/nonfirst-choice counts, base score, lexical-unit evidence and last-use time. The currently remembered deliberate choice for a spelling also retains its selection time. A new deliberate nonfirst choice replaces the prior selection marker for that spelling; no chronological sequence is saved by Personal Learning. App identifiers are no longer stored in vocabulary rows. First-choice Space/number/mouse acceptance only updates usage, never preference strength or the selection marker. Every three nonfirst choices add one frequency point up to 32. Separately, one deliberate selection is enough to lead the next exact normalized-spelling search, after any explicit personal-phrase pin. Prefixes save only consumed spelling. Literal, personal/verbatim, punctuation, delimiter and legacy automatic confirmations are excluded, and a confirmed output is kept as one candidate-choice entry.

**There is no age expiry or strength decay.** Records remain until Forget, clear or capacity eviction; a maximum of 5,000 global records is retained, removing the least recently used entries first with deterministic identity ties when full. This longer retention applies to existing records still present at migration, but cannot restore previously removed data. Personal Learning does not create input history; the separately opted-in Input History feature below has its own retention and deletion. There is no synchronization, learning export/import or remote aggregation.

**Manage Learning Data…** provides global vocabulary search, Forget and clear. Forgetting or clearing immediately invalidates learned ranking and exact-choice placement, including pending candidates; older queued saves cannot undo a newer deletion. Clearing learning leaves Input History, explicit phrases and the retired shared archive alone. Disabling Personal Learning, secure input and disabled-language filtering suppress both saved candidates and token/whole learning effects. Enabled languages never grant recording consent. Preview never records.

The archive remains at:

```text
~/Library/Application Support/SI/Personalization/application-memory-v1.json
```

New writes use vocabulary-only schema 4. The archive has a 64 MiB limit, owner-only directory/file permissions and atomic replacement. SI does not encrypt it; software under the same user, administrators or backups may access it. Saves run off the main actor, coalesce for 300 ms and flush at normal termination; forced termination can lose recent updates. Open/migration errors pause recording and learned suggestions; save/erase errors appear in Settings. Learning consent remains in UserDefaults. The retired per-app learning exclusion key is removed. No personal data is supplied to Sparkle or another network service.

### Sentence learning

Sentence Learning uses up to the first 2,048 UTF-16 units exposed by the active InputMethodKit text client around a passed-through Return or Command–Return. It can fall back to available text before the caret within that limit. That range may include existing, edited or pasted text. The original snapshot becomes one learning observation if the later text no longer contains it, the field loses focus or the client is no longer readable. Secure and direct-input contexts are excluded. Snapshots are local and transient.

The engine segments the queued text and updates the owner-only, unencrypted `SI/Personalization/model.si-user` profile under Application Support. It saves derived words, word frequencies, word grams and opaque batch IDs. For recognized web addresses, the learned word is the host and any explicit HTTP(S) scheme. A recognized email address is saved in full as a word and can be removed in Personal Phrases. Captured text is held in memory until processed and discarded after the batch succeeds. Failed batches can be retried while SI is running. Normal termination flushes pending work when storage is available. Opening a valid profile removes the retired recent-samples files without decoding them. Existing derived statistics are retained.

**Personal Phrases → Delete All…** clears the derived model, manually added entries and pending learning. Later eligible Return field snapshots can populate the model again. Candidate-choice preferences and Input History have separate controls. **Delete Old Sentence History…** under **Personal Phrases** can delete the older retired SQLite archive, whose contents remain unopened.

## Input History

**Save Input History** in **Input History** has independent `inputHistory.enabled` consent and defaults to off. Language, Personal Learning and retired history settings do not enable it. When on, each successful SI submission saves a new UUID, exact consumed spelling, exact submitted output (including SI-inserted suffixes), timestamp, optional language/mixed identity and commit reason. Repeat submissions stay separate. Literal English/code, personal phrases and punctuation are included. Historical automatic-confirmation records remain readable. Prefixes save only their committed spelling/output; the pending suffix stays unrecorded until committed. This is a record of SI submissions, without document readback or monitoring raw key events.

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

The [Personal Phrases page](USER_PHRASES.md) manages the private user model’s `user.silex` entries, including their text, optional reading and frequency. Entries have no automatic expiry. Deleting or changing an identity removes associated word grams. Future confirmations can recreate deleted words. **Delete All…** clears the shared model. The separate shortcut archive `phrases-v1.json` stays on disk as retired data.

There is no app-vocabulary export/import, synchronization, remote aggregation or automatic document harvesting.


## Ranking and safeguards

Global frequency rewards affect whole/prefix and eligible token ranking with a shared 32-point cap and no decay. Chinese single-character preferences remain limited to their own spelling; English words and Chinese words of at least two characters can influence matching internal tokens. Token/whole bonuses use their maximum rather than adding twice. Immediate last-choice placement requires the whole normalized spelling and does not add unbounded score or leak into pending suffixes. Personal-phrase pins keep their explicit contract. Personal/verbatim paths receive no automatic-learning bonus. Secure event input suppresses all automatic learning and learned suggestions; it is a conservative process-wide check, not a detector for every sensitive field. Disabling learning, deletion and clear also stop token effects. Existing core contextual APIs remain library fixtures and do not enable previous-word product learning.
