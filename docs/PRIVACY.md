# Personal data and privacy

SI processes input locally with no analytics, keystroke logger, or cloud dependency for typing. User-initiated software updates are the only app network feature.

## Software update requests

**Check for Updates…** uses Sparkle 2.10.0 to request SI's public HTTPS appcast on `downloads.caterm.com`, followed by an update archive only when the user chooses to download/install. Automatic checks, automatic installation, and system-profile submission are disabled. Requests expose ordinary connection metadata, including the IP address and HTTP user agent (which may identify app/framework/OS versions), to the download service. They do not include composition text, committed text, host-document text, personal phrases, learned preferences, or chronological typing history. The updater has no reference to input sessions or personal-data models.

Sparkle retains its ordinary updater preferences and last-check information in the app's bundle defaults domain (`com.caterm.inputmethod.si`) and may cache update downloads. This is separate from language/learning consent and private phrase/learning archives. No vocabulary is downloaded while typing. Closing Settings keeps the input server alive; choosing to install an update restarts SI after its normal pending-write flush. A log out/back in may still be needed if macOS does not resume the input method.

## Independently opted-in app vocabulary and history

Both options in **App Vocabulary and History** default to off. Enabling one does not enable the other or grant consent to uploading anything. Scope is the IMK client application's bundle identifier; browser sites share their browser's scope. SI does not query the document, clipboard, window title, URL or chat recipient, and requests no Accessibility/Input Monitoring permission or global event tap.

App vocabulary retains the application identifier, normalized consumed spelling, output/language/mixed identity, bounded decaying strength, aggregate confirmation count, base score, lexical-unit evidence and last-use time. Explicit candidate selection and ordinary default Space acceptance each count as one use. Literal, personal/verbatim paths, history suggestions, delimiter commits and automatic confirmation are excluded. There are at most 5,000 entries across all apps, with 90-day inactivity expiry, the existing 14-day strength half-life and bounded ranking bonus. App vocabulary is the only automatic vocabulary-learning feature. Disabling or pausing it restores base ranking, with no shared-profile fallback or previous-word pair learning.

App history is a distinct consent allowing sensitive literal text retention. It keeps at most 1,000 deduplicated units across apps for 30 days without use. Each row retains exact source spelling and output (each at most 4,096 UTF-8 bytes), required language identities, application identifier, bounded aggregate use count and the most recent use time. It does not retain every occurrence or the order of keystrokes. Units are saved only when unmodified Return/keypad Enter is passed to the host; a Return consumed to commit composition does not save a unit. Shift/shortcut Return does not delimit a record. SI cannot confirm that a message was sent or a command executed.

An unfinished draft exists only in its input controller, for at most five minutes without activity. Escape, committed-text editing/navigation, shortcuts/paste, IMK focus/commit callbacks, configuration/consent changes, secure input, automatic confirmation and paths containing personal/verbatim nodes discard it. Recording after such a boundary waits for the next unmodified host Return or new client. Printable events passed through to an application may be included; they are not read back from the application. Available selection offsets detect unexpected caret movement, but hosts with missing offsets/events or text transformations can make the observed unit differ from final text. History completions require a nonempty composition and explicit candidate acceptance, never read surrounding text, never train word/context preferences, and do not repeat the committed prefix.

**Manage App Data…** supports search and application filtering, Forget, independent per-app vocabulary/history pause, and clearing either type for one app or all apps. Pause stops both recording and suggestions while preserving saved rows. The main section's **Clear All App Data…** removes both types, including unreadable archives, without deleting shared preferences or explicit phrases. Clearing invalidates unfinished drafts and pending candidates. Old queued writes cannot undo a newer clear. Disabled languages cannot be reintroduced by saved candidates. Settings preview offers app scopes and never records data.

App vocabulary and history are stored separately from explicit personal phrases:

```text
~/Library/Application Support/SI/Personalization/application-memory-v1.json
```

The version-1 JSON archive has a 64 MiB file limit, owner-only directory/file permissions, and atomic replacement. It is not encrypted by SI and may be accessible to other software under the same user, administrators or backups. The existing backup limitations apply to deletion. Startup and daily maintenance physically prune expired entries; expired rows are excluded from suggestions before cleanup. Oldest rows are evicted first, with deterministic identity tie-breaking. Saves are off the main actor, coalesced for 300 ms and flushed on normal termination. Forced termination can lose recent updates. Open/corruption failures pause both features until explicit clear; save/erase failures are shown in Settings. Per-app exclusion settings are stored in UserDefaults alongside the independent consent flags. No app-vocabulary/history data is supplied to Sparkle or any network service.

## Retired shared learning data

The separate **Personal learning** feature, previous-word pair option and shared-preference manager have been removed. SI no longer opens, ranks with, updates, expires or automatically migrates the former shared archive:

```text
~/Library/Application Support/SI/Personalization/preferences-v1.json
```

Its old `personalization.enabled` and `personalization.contextEnabled` UserDefaults flags do not enable app vocabulary, app history or any fallback. Shared entries have no app identity and are never copied into every app's vocabulary. Removing the feature does not automatically erase this sensitive file. If it exists, **App Vocabulary and History → Delete Old Shared Learning Data…** offers confirmed deletion of that file and the two retired consent flags. SI only checks file existence, without decoding its contents, and deletion happens on the storage actor. Progress and failure are shown independently of current app-data errors; a failed deletion can be retried. This operation does not alter app vocabulary/history or explicit personal phrases. The inactive old file has no further automatic expiry cleanup; delete it through this control when no longer needed. External backups remain outside SI's deletion controls.

## Explicit personal phrases

The separate [personal phrase dictionary](USER_PHRASES.md) retains user-entered codes, output text, language, pin setting, and stable identifiers. It is available with learning off, stores up to 1,000 phrases without automatic expiry, and supports edit, individual deletion, clear, and explicit JSON import/export. Personal phrases are not duplicated into automatic learning records or used as preceding-word context. Clearing learning and clearing the dictionary are separate actions; exported files and external backups are outside either clear operation.

There is no learning/history export/import, synchronization, remote aggregation or automatic document harvesting. App history is a bounded record of observed input units, not a reliable transcript of sent messages, executed commands or final document text.


## Ranking and safeguards

App word preferences use the shared core ranking model: 14-day strength half-life, logarithmic bonus capped at 32 points, and application-specific whole/prefix spelling. Eligible English words and Chinese words of two or more characters can influence internal tokens; Chinese single-character preferences remain limited to their own spelling. Token and whole bonuses use their maximum rather than being added twice. This does not save decomposed sentence tokens. Personal/verbatim paths receive no bonus. Secure event input suppresses recording, app ranking and history suggestions; it is a conservative process-wide check, not a detector for every sensitive field. Pausing, deletion, clear and expiry also stop token effects. Enabled-language settings never grant learning/history consent. Preview never records.
