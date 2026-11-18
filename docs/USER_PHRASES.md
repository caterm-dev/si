# Personal phrases

**SI Settings → Personal Phrases** directly lists the active `user.silex` vocabulary in `~/Library/Application Support/SI/Personalization/model.si-user/`. It includes entries created by Sentence Learning and entries explicitly added here. Search by text or reading, then use **Add Phrase…**, **Edit** or **Delete**.

The editor exposes exact output text, Chinese/English reading and unsigned integer frequency. Readings use lowercase ASCII letters and apostrophes (use `v` for ü), up to 256 bytes. Text is nonempty, at most 4,096 UTF-8 bytes and cannot contain control characters. Entries without a reading remain visible and editable; they do not provide a spelling lookup until a reading is assigned. Duplicate text/reading/index identities are rejected. There is no separate 1,000-entry phrase limit, pin, shortcut expansion, or JSON import/export.

The stored user model participates in eligible conversion and learns from confirmed candidates by default. Enabled languages and secure/direct-input safeguards apply.

## Storage and deletion

The profile retains owner-only snapshot directories and atomically publishes the paired `user.silex` and `user.sigram`. File access and rebuilding run on the storage actor, away from the key-event path. Edits compare the exact original row under the Rust profile lock; stale or duplicate edits fail visibly. Reopen the editor to retry against the latest entry after learning updates it.

Frequency-only edits preserve associated grams. Deleting or changing a word's text/reading drops grams involving that identity and remaps surviving word IDs, preserving unrelated counts and lookup aliases. Accepted queued learning completes before an edit. Future learning can add a deleted word again; deletion is not a permanent exclusion rule. Entries have no automatic expiry. **Delete All…** clears this shared vocabulary, word grams and pending learning after confirmation. Personal Learning and Input History have separate deletion controls.

The old `SI/UserDictionary/phrases-v1.json` archive is no longer loaded, changed or migrated. Existing copies remain on disk for manual recovery/deletion. Core personal-phrase types remain available to library fixtures but are no longer fed by the app.

Native keyboard, VoiceOver, appearance and host checks are listed in [testing](TESTING.md#personal-phrase-checks).
