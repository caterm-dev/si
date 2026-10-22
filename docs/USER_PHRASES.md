# Personal phrases

Open **SI Settings → Personal Phrases → Manage Personal Phrases…**. Add an input code, the exact phrase text, and a candidate language. Enabling that language makes the phrase available; no active-language mode is introduced.

- Codes are case-insensitive ASCII letters with optional internal apostrophes, at most 64 normalized bytes. Leading/trailing or repeated apostrophes, digits, and unreachable codes are rejected. Chinese codes normalize ü/`u:` to `v`; type `v` through SI.
- Phrase text is preserved exactly, including case, spaces, and emoji. Empty/whitespace-only text, line breaks, control characters, or more than 1,024 UTF-8 bytes are rejected. Unicode joiners are allowed for joined emoji and scripts.
- Full-code matches use a local prior based on dictionary size; **Prefer this phrase for its full code** gives an exact full-code match explicit priority. Incomplete codes use the shared spelling channel. Chinese constructed nodes use MSIME's 10,000 initial insertion prior and retain the one-bit pin preference; this is a ranking prior, not observed frequency. English composition retains the previous local prior. Other enabled-language candidates and literal input remain available.
- Candidate labels identify personal phrases. Their language comes from the saved setting; it is not guessed from the output script.
- Editing preserves the entry identifier. Identical code/language/text entries cannot be added twice; multiple different outputs for one code are allowed.
- Personal phrases are independent of automatic learning. They do not create learning records or become prior-word context. Clearing learning data leaves phrases intact; clearing the phrase dictionary leaves unrelated learned preferences intact.
- Secure event input suppresses phrase suggestions conservatively. It does not delete phrases.

## Storage and deletion

The dictionary retains up to 1,000 entries without automatic expiry, until the user edits, deletes, or clears them. The local path is:

```text
~/Library/Application Support/SI/UserDictionary/phrases-v1.json
```

The directory uses owner-only access (0700), and the file uses owner read/write access (0600). Files are not encrypted by SI. Saves run on an actor and use atomic replacement; older queued writes cannot undo newer deletions. Settings reports save failures and supports retry. Corrupt or unsupported files are preserved until explicit clearing. No cloud sync or automatic import runs.

## Import and export

**Import…** accepts an SI dictionary JSON file, at most 4 MiB. Import validates every entry and the complete result before replacing in-memory state. It adds new phrases, skips content duplicates, preserves local pin settings, and assigns a new identifier when an imported identifier collides with a different local entry. It never silently drops old entries to fit the capacity. Changes during an asynchronous import cancel application of that import, preventing a late result from undoing a clear or edit.

**Export…** creates a snapshot containing only manually saved phrases, not learning data. The standard save dialog lets the user choose its location. Exported copies contain personal text and are not deleted when SI's private dictionary is cleared. Keep their location and access permissions appropriate to their content.

Format example:

```json
{
  "format": "SI User Dictionary",
  "version": 1,
  "entries": [
    {
      "id": "CA6D0233-55CE-4F39-8624-9A1DA2083101",
      "input": "xm",
      "text": "项目代号",
      "language": "zh-Hans",
      "isPinned": true
    }
  ]
}
```

Supported language identifiers are `en` and `zh-Hans`. Entries are data, never executable instructions. Chinese codes also form nodes in longer Chinese compositions: `xm` → `小明` can supply a personal path for `woaixm`. Saved codes augment the ordinary Chinese reading rather than replacing it. Personal codes can also be selected as explicit leading prefixes, leaving the remaining spelling editable. Apostrophes constrain typed boundaries. All direct saved prefix choices stay available independently of the constructed-node fanout. The exact saved text is concatenated without added spaces, so include a space in the phrase itself when one is required. Chinese/English lexical paths remain deferred during the Chinese migration.

The Chinese migration builds, but the full regression suite still fails; native personal-phrase behavior remains unverified. See [the current implementation plan](IMPLEMENTATION_PLAN.md).

Constructed paths use at most 12 personal alternatives per language for each matching code, with preferred phrases first, and stop before output would exceed 4,096 UTF-8 bytes. Direct full-code/prefix matches retain all alternatives independently of that search bound. Prefix selection allows a long expansion to be confirmed in pieces without truncating text. Any constructed path containing a personal phrase is excluded from automatic learning and previous-word context, even when its other words came from the built-in vocabulary.
