# Personal learning and privacy

SI processes input locally with no analytics, keystroke logger, or cloud dependency for typing. User-initiated software updates are the only app network feature.

## Software update requests

**Check for Updates…** uses Sparkle 2.10.0 to request SI's public HTTPS appcast on `downloads.caterm.com`, followed by an update archive only when the user chooses to download/install. Automatic checks, automatic installation, and system-profile submission are disabled. Requests expose ordinary connection metadata, including the IP address and HTTP user agent (which may identify app/framework/OS versions), to the download service. They do not include composition text, committed text, host-document text, personal phrases, learned preferences, or chronological typing history. The updater has no reference to input sessions or personal-data models.

Sparkle retains its ordinary updater preferences and last-check information in the app's bundle defaults domain (`com.caterm.inputmethod.si`) and may cache update downloads. This is separate from language/learning consent and private phrase/learning archives. No vocabulary is downloaded while typing. Closing Settings keeps the input server alive; choosing to install an update restarts SI after its normal pending-write flush. A log out/back in may still be needed if macOS does not resume the input method.

## What is retained

Personal learning is **off by default** and independent of enabled languages. Enabling it permits local storage of these aggregate fields:

- Normalized spelling, including explicit Pinyin syllable separators.
- Chosen candidate text and language identity.
- Decaying selection strength and the most recent use time.
- With the separate previous-word option enabled: the preceding chosen candidate text and language/mixed identity, as an aggregate pair rather than an ordered history.

These records can reveal personal words or preferences. They are sensitive even though they are not a chronological record of typing. Shared learning retains no sentence history, host-document content, per-keystroke log, or app-usage log. Separately opted-in app history can retain literal text and application identity as described below. Neither mode creates explicit user phrases automatically.

Language, punctuation, automatic-confirmation and learning-consent settings are stored in the stable `com.caterm.si` UserDefaults domain. This domain is retained when the input-method bundle identifier changes to `com.caterm.inputmethod.si`, preserving existing choices without granting new learning consent. Learned preferences are stored at:

```text
~/Library/Application Support/SI/Personalization/preferences-v1.json
```

The containing directory uses owner-only access (0700), and the file uses owner read/write access (0600). The JSON file is **not encrypted by SI**. Other software running as the same user, administrators, and device backups may have access. Clearing SI's data does not erase copies previously made by external backup software.

## When learning happens

- An explicit candidate selection (number, mouse, or navigation followed by Space) contributes weight 1. Accepting the default with Space contributes zero: it does not create, reinforce or refresh a saved preference, or become the preceding chosen word for later learning.
- Literal candidates, candidates with unrecognized verbatim spans, personal phrases (including longer paths containing them), Return committing original text, cancelled compositions, and focus/shortcut boundaries do not contribute learning. Tab/punctuation commits do not train, whether they confirm a candidate or retain literal spelling.
- macOS secure event input suppresses both learning updates and personalized ranking. This is a conservative process-wide check, not a general detector for every kind of sensitive field. Pause learning whenever input should not affect saved preferences.
- Candidate preview never records preferences.
- An explicit prefix selection records only its consumed spelling and chosen output. The still-marked remainder stays in session memory and is not copied into that preference. Labels distinguish complete, prefix, personal, and verbatim-containing candidates.
- Optional automatic prefix confirmation never trains learning or supplies previous-word context. Its bounded source/output boundary evidence and stability observations are transient and client-local, reset on composition/host/configuration boundaries, and are not stored in an archive or typing history. Enabling automatic confirmation does not enable learning.

Ranking uses a 14-day half-life and logarithmic strength, with up to 32 points for frequency/recency and 12 additional points for an eligible previous-word pair. Whole/prefix preferences apply before bounded presentation selection, using only the relevant full or consumed spelling. This changes which bounded results survive; candidate merging retains all results produced by decoding and the literal fallback. Disabled languages cannot be revived by stored preferences. No active-language mode is inferred from recent choices.

Existing single-language word records also influence matching tokens inside longer compositions before bounded search prunes alternatives. Chinese single-character output is excluded from this transfer, including for old records; it remains eligible for ranking its own full or explicitly consumed spelling. Chinese words with at least two characters and English words retain token learning. Their input-length-weighted average shares the same 32-point cap with whole-input preferences; both are never added together. This adds no retained fields, input history, or automatic token harvesting: confirming a composed candidate records only that consumed spelling/output as before. Personal/verbatim paths receive no token bonus. Pausing, deleting, clearing, expiry, and secure-event suppression apply to token ranking too. Previous-word records remain separate and are not treated as token frequency records.

## Optional previous-word context

**Learn from the previous chosen word** is off by default and requires personal learning to be enabled. It stores aggregate preferences linking one previous chosen candidate to a current spelling/candidate. It does not read surrounding client text or retain ordered sentence histories. A candidate itself may be a multi-character phrase or a constructed composition, so pairs can still reveal private content.

The previous candidate is held in memory per InputMethodKit client for at most five minutes. Cancel, literal/host-boundary commits, deactivation/focus callbacks, navigation outside composition, language changes, consent changes, and clear reset eligibility. Manual phrases and literal candidates are excluded. Correct delivery of macOS focus callbacks remains a manual verification requirement. Turning this option off stops recording and using pairs; saved pairs remain manageable until explicitly removed or expired.

## Retention and controls

- Turning **Personal learning** off pauses recording and personalized ranking. Existing preferences remain available for management and later reuse. Saved records do not distinguish past default acceptances from deliberate choices; the new recording rule does not automatically erase old records.
- **Manage Saved Preferences… → Forget** removes a specific preference.
- **Clear Saved Data…** removes all saved learning preferences after confirmation, without changing language settings.
- Records become ineligible for ranking after 90 days without use. Physical cleanup occurs when data is loaded and at least once every 24 hours while SI is running.
- The store retains at most 5,000 entries, evicting the oldest entries first, with a deterministic identity tie-break.
- Single-candidate and contextual entries share that capacity and expiry policy. The manager shows “After …” for contextual records and can search by the preceding word.

Writes run on a storage actor, use atomic replacement, and are coalesced for 300 ms. Normal termination flushes pending changes; a crash or forced termination can lose recent unsaved learning. Revision guards prevent older queued writes from restoring entries after a newer deletion or clear. Read/write errors are shown in Settings. Unreadable or unsupported data is not silently replaced; recording stays paused until the user explicitly clears it. If clearing fails, SI reports the failure instead of claiming that on-disk deletion succeeded.

The stable learning filename above now holds schema version 2. Version 1 records migrate locally on load, preserving existing preferences and their mixed-language identities. Reads reject unsupported schemas and files above 16 MiB, with bounded reads even if a file grows after its metadata is checked.

## Explicit personal phrases

The separate [personal phrase dictionary](USER_PHRASES.md) retains user-entered codes, output text, language, pin setting, and stable identifiers. It is available with learning off, stores up to 1,000 phrases without automatic expiry, and supports edit, individual deletion, clear, and explicit JSON import/export. Personal phrases are not duplicated into automatic learning records or used as preceding-word context. Clearing learning and clearing the dictionary are separate actions; exported files and external backups are outside either clear operation.

There is no learning/history export/import, synchronization, remote aggregation or automatic document harvesting. App history is a bounded record of observed input units, not a reliable transcript of sent messages, executed commands or final document text.


## Independently opted-in app vocabulary and history

Both options in **App Vocabulary and History** default to off. Enabling one does not enable the other or grant consent to uploading anything. Scope is the IMK client application's bundle identifier; browser sites share their browser's scope. SI does not query the document, clipboard, window title, URL or chat recipient, and requests no Accessibility/Input Monitoring permission or global event tap.

App vocabulary retains the application identifier, normalized consumed spelling, output/language/mixed identity, bounded decaying strength, aggregate confirmation count, base score, lexical-unit evidence and last-use time. Unlike legacy shared learning, ordinary default Space acceptance counts as one use. Literal, personal/verbatim paths, history suggestions, delimiter commits and automatic confirmation are excluded. There are at most 5,000 entries across all apps, with 90-day inactivity expiry, the existing 14-day strength half-life and bounded ranking bonus. When app vocabulary is enabled, typing uses it instead of legacy shared frequency/previous-word learning. Disabling it restores the shared option without migrating or deleting old records.

App history is a distinct consent allowing sensitive literal text retention. It keeps at most 1,000 deduplicated units across apps for 30 days without use. Each row retains exact source spelling and output (each at most 4,096 UTF-8 bytes), required language identities, application identifier, bounded aggregate use count and the most recent use time. It does not retain every occurrence or the order of keystrokes. Units are saved only when unmodified Return/keypad Enter is passed to the host; a Return consumed to commit composition does not save a unit. Shift/shortcut Return does not delimit a record. SI cannot confirm that a message was sent or a command executed.

An unfinished draft exists only in its input controller, for at most five minutes without activity. Escape, committed-text editing/navigation, shortcuts/paste, IMK focus/commit callbacks, configuration/consent changes, secure input, automatic confirmation and paths containing personal/verbatim nodes discard it. Recording after such a boundary waits for the next unmodified host Return or new client. Printable events passed through to an application may be included; they are not read back from the application. Available selection offsets detect unexpected caret movement, but hosts with missing offsets/events or text transformations can make the observed unit differ from final text. History completions require a nonempty composition and explicit candidate acceptance, never read surrounding text, never train word/context preferences, and do not repeat the committed prefix.

**Manage App Data…** supports search and application filtering, Forget, independent per-app vocabulary/history pause, and clearing either type for one app or all apps. Pause stops both recording and suggestions while preserving saved rows. The main section's **Clear All App Data…** removes both types, including unreadable archives, without deleting shared preferences or explicit phrases. Clearing invalidates unfinished drafts and pending candidates. Old queued writes cannot undo a newer clear. Disabled languages cannot be reintroduced by saved candidates. Settings preview offers app scopes and never records data.

Data is stored separately from shared learning and explicit phrases:

```text
~/Library/Application Support/SI/Personalization/application-memory-v1.json
```

The version-1 JSON archive has a 64 MiB file limit, owner-only directory/file permissions, and atomic replacement. It is not encrypted by SI and may be accessible to other software under the same user, administrators or backups. The existing backup limitations apply to deletion. Startup and daily maintenance physically prune expired entries; expired rows are excluded from suggestions before cleanup. Oldest rows are evicted first, with deterministic identity tie-breaking. Saves are off the main actor, coalesced for 300 ms and flushed on normal termination. Forced termination can lose recent updates. Open/corruption failures pause both features until explicit clear; save/erase failures are shown in Settings. Per-app exclusion settings are stored in UserDefaults alongside the independent consent flags. No app-vocabulary/history data is supplied to Sparkle or any network service.
