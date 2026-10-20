# Personal learning and privacy

SI processes input locally and contains no network client, analytics, keystroke logger, or cloud dependency.

## What is retained

Personal learning is **off by default** and independent of enabled languages. Enabling it permits local storage of these aggregate fields:

- Normalized spelling, including explicit Pinyin syllable separators.
- Chosen candidate text and language identity.
- Decaying selection strength and the most recent use time.
- With the separate previous-word option enabled: the preceding chosen candidate text and language/mixed identity, as an aggregate pair rather than an ordered history.

These records can reveal personal words or preferences. They are sensitive even though they are not a chronological record of typing. There is no sentence history, host-document content, per-keystroke log, or app-usage log. The current implementation does not harvest arbitrary literal text or create user phrases automatically.

Language, punctuation, and learning-consent settings are stored in the stable `com.caterm.si` UserDefaults domain. This domain is retained when the input-method bundle identifier changes to `com.caterm.inputmethod.si`, preserving existing choices without granting new learning consent. Learned preferences are stored at:

```text
~/Library/Application Support/SI/Personalization/preferences-v1.json
```

The containing directory uses owner-only access (0700), and the file uses owner read/write access (0600). The JSON file is **not encrypted by SI**. Other software running as the same user, administrators, and device backups may have access. Clearing SI's data does not erase copies previously made by external backup software.

## When learning happens

- An explicit candidate selection (number, mouse, or navigation followed by Space) contributes weight 1. Accepting the default with Space contributes zero: it does not create, reinforce or refresh a saved preference, or become the preceding chosen word for later learning.
- Literal candidates, candidates with unrecognized verbatim spans, personal phrases (including longer paths containing them), Return committing original text, cancelled compositions, and focus/shortcut boundaries do not contribute learning. Tab/punctuation commits do not train, whether they confirm a candidate or retain literal spelling.
- macOS secure event input suppresses both learning updates and personalized ranking. This is a conservative process-wide check, not a general detector for every kind of sensitive field. Pause learning whenever input should not affect saved preferences.
- Candidate preview never records preferences.
- A prefix confirmation records only its consumed spelling and chosen output. The still-marked remainder stays in session memory and is not copied into that preference. Labels distinguish complete, prefix, personal, and verbatim-containing candidates.

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

There is currently no learning-data export/import, synchronization, per-app persistent profile, or full sentence-history model. Such additions must extend this document and provide corresponding retention and deletion controls.
