# Personal data and privacy

SI processes input locally with no analytics, keystroke logger, or cloud dependency for typing. User-initiated software updates are the only app network feature.

## Model experiments

The input method currently uses local dictionaries without a language model. The
separate `llm/` experiments use explicit offline training data and are not connected
to typed text, personal phrases or app vocabulary. Future model integration must
preserve the input method's privacy and retention contract.

## Software update requests

**Check for Updates…** uses Sparkle 2.10.0 to request SI's public HTTPS appcast on `downloads.caterm.com`, followed by an update archive only when the user chooses to download/install. Automatic checks, automatic installation, and system-profile submission are disabled. Requests expose ordinary connection metadata, including the IP address and HTTP user agent (which may identify app/framework/OS versions), to the download service. They do not include composition text, committed text, host-document text, personal phrases, learned preferences, or chronological typing history. The updater has no reference to input sessions or personal-data models.

Sparkle retains its ordinary updater preferences and last-check information in the app's bundle defaults domain (`com.caterm.inputmethod.si`) and may cache update downloads. This is separate from language/learning consent and private phrase/learning archives. No vocabulary is downloaded while typing. Closing Settings keeps the input server alive; choosing to install an update restarts SI after its normal pending-write flush. A log out/back in may still be needed if macOS does not resume the input method.

## Opt-in app vocabulary

**Learn vocabulary separately for each app** in **App Vocabulary** defaults to off. Scope is the IMK client application's bundle identifier; browser sites share their browser's scope. SI does not query the document, clipboard, window title, URL or chat recipient, and requests no Accessibility/Input Monitoring permission or global event tap.

App vocabulary retains the application identifier, normalized consumed spelling, output/language/mixed identity, bounded decaying strength, aggregate usage and nonfirst-choice counts, base score, lexical-unit evidence and last-use time. Every eligible candidate confirmation counts as one use. Accepting the displayed first candidate by Space, number or mouse leaves ranking strength unchanged apart from ordinary decay. Each three choices of a nonfirst candidate add one ranking point, with a 32-point cap. Only aggregate counts are kept; no sequence of selections or additional timestamps is retained. Literal, personal/verbatim paths, delimiter commits and automatic confirmation are excluded. There are at most 5,000 entries across all apps, with 90-day inactivity expiry, the existing 14-day strength half-life and bounded ranking bonus. App vocabulary is the only automatic vocabulary-learning feature. Disabling or pausing it restores base ranking, with no shared-profile fallback or previous-word pair learning.

**Manage App Data…** supports search and application filtering, Forget, per-app vocabulary pause, and clearing vocabulary for one app or all apps. Pause stops recording and suggestions while preserving saved rows. **Clear All App Data…** removes the app archive, including unreadable data, without deleting shared preferences or explicit phrases. Clearing invalidates pending candidates. Old queued writes cannot undo a newer clear. Disabled languages cannot be reintroduced by saved candidates.

App vocabulary is stored separately from explicit personal phrases:

```text
~/Library/Application Support/SI/Personalization/application-memory-v1.json
```

The filename is retained for compatibility; new writes use a vocabulary-only version-3 JSON schema. The archive has a 64 MiB file limit, owner-only directory/file permissions and atomic replacement. SI does not encrypt it; other software under the same user, administrators or backups may be able to access it. Startup and daily maintenance physically prune expired entries, and expired rows are excluded from suggestions before cleanup. Oldest rows are evicted first with deterministic identity tie-breaking. Saves are off the main actor, coalesced for 300 ms and flushed on normal termination. Forced termination can lose recent updates. Open/corruption or migration failures pause recording/suggestions until recovery; save/erase failures are shown in Settings. Vocabulary consent and per-app exclusions remain in UserDefaults. No app vocabulary data is supplied to Sparkle or any network service.

## Removed App History

App History recording and completions have been removed. SI no longer accumulates source/output drafts, includes printable passthrough text in a history unit or records text when Return reaches the host. The old history consent and exclusion defaults are removed and never enable vocabulary learning.

On the next successful load by the new app, an existing version-1 or version-2 app archive is validated for vocabulary and atomically rewritten as version 3 without its retired history field. Words and total usage counts remain subject to their existing retention rules. Older strengths mixed default acceptance and deliberate corrections and are reset to neutral, with new correction counts starting at zero. Schema-3 correction counts and ranking strengths survive restart. No old shared-learning archive is imported. Corrupt or unsupported archives remain untouched with a visible storage error until explicitly cleared; migration write failures also pause loading. Explicit personal phrases and the separate retired shared-learning archive are unaffected. Removing local history fields cannot remove copies in external backups or guarantee forensic erasure of previous filesystem data.

## Retired shared learning data

The separate **Personal learning** feature, previous-word pair option and shared-preference manager have been removed. SI no longer opens, ranks with, updates, expires or automatically migrates the former shared archive:

```text
~/Library/Application Support/SI/Personalization/preferences-v1.json
```

Its old `personalization.enabled` and `personalization.contextEnabled` UserDefaults flags do not enable app vocabulary or any fallback. Shared entries have no app identity and are never copied into every app's vocabulary. Removing the feature does not automatically erase this sensitive file. If it exists, **App Vocabulary → Delete Old Shared Learning Data…** offers confirmed deletion of that file and the two retired consent flags. SI only checks file existence, without decoding its contents, and deletion happens on the storage actor. Progress and failure are shown independently of current app-data errors; a failed deletion can be retried. This operation does not alter app vocabulary or explicit personal phrases. The inactive old file has no further automatic expiry cleanup; delete it through this control when no longer needed. External backups remain outside SI's deletion controls.

## Explicit personal phrases

The separate [personal phrase dictionary](USER_PHRASES.md) retains user-entered codes, output text, language, pin setting, and stable identifiers. It is available with learning off, stores up to 1,000 phrases without automatic expiry, and supports edit, individual deletion, clear, and explicit JSON import/export. Personal phrases are not duplicated into automatic learning records or used as preceding-word context. Clearing learning and clearing the dictionary are separate actions; exported files and external backups are outside either clear operation.

There is no app-vocabulary export/import, synchronization, remote aggregation or automatic document harvesting.


## Ranking and safeguards

App word preferences use the shared core ranking model: 14-day strength half-life, logarithmic bonus capped at 32 points, and application-specific whole/prefix spelling. Eligible English words and Chinese words of two or more characters can influence internal tokens; Chinese single-character preferences remain limited to their own spelling. Token and whole bonuses use their maximum rather than being added twice. This does not save decomposed sentence tokens. Personal/verbatim paths receive no bonus. Secure event input suppresses recording and app ranking; it is a conservative process-wide check, not a detector for every sensitive field. Pausing, deletion, clear and expiry also stop token effects. Enabled-language settings never grant learning consent. Preview never records.
