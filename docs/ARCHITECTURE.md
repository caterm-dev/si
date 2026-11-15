# Architecture

## Product contract

SI exposes one macOS input source. Settings contain a set of enabled languages, not an active language. Every enabled provider is queried for the current composition. Matching candidates coexist; ambiguity is a choice for the user rather than a reason to switch modes. Literal input is always offered.

## Data flow

The app links the Rust conversion engine through a C ABI. Swift owns the
client-local input session, consent and application preferences, marked
text, candidate window and commit handling. The bridge validates original
UTF-8 spans and converts them to Swift character positions. The host adapter
uses UTF-16 offsets for AppKit ranges.

```text
Host key event → SIInputController → client-local InputSession
  → immutable CandidateRequest → background candidate worker
  → Rust decoder → ranked lexical candidates and source evidence
  → local preference and presentation policies
  → revision-checked CandidateResult → AppKit candidate window or commit
```

Xcode copies `target/si-data/main.silex` and `target/si-data/words.sigram`
into the app's `Contents/Resources/SIEngine/` directory. The build validates
the pair before packaging. Candidate source spans are relative to the current composition.

## Rust conversion

`CandidateEngine` borrows a loaded base resource pair and an optional
loaded user pair. It indexes both lexicons once and searches them on every
request for the enabled languages. Lookup index 0 is full Pinyin and
index 1 is English. Base and user entries share statistical evidence only
when exact output bytes, primary reading and lookup index agree. Every
gram lookup uses the IDs of its own lexicon. A newly loaded user snapshot
can be used by constructing a new engine.

Input normalization maps spelling to UTF-8 grapheme boundaries in the
original input. The
[`unicode-segmentation` 1.13.3 crate](https://github.com/unicode-rs/unicode-segmentation)
implements UAX #29 and is distributed under MIT or Apache-2.0. Pinyin
apostrophes constrain syllable cuts and belong to the preceding syllable
for prefix consumption. Umlaut aliases share a spelling but consume their
own bytes. English uses case-insensitive lookup with typed capitalization
applied to output. Constructed paths join Chinese words directly and
insert a space at English word boundaries. Bilingual paths can preserve a
bounded unrecognized span next to a known Chinese word. Those paths and
paths containing a personal phrase preserve their token bytes without
adding spaces and are excluded from learning. An exact literal is available
for every nonempty input.

Conversion uses a word lattice with up to 24 paths per input position,
language combination and scoring lane, or six in preview. The base lane preserves dictionary
paths when user evidence is enabled. A bounded lane keeps personal and
verbatim paths available with their learning exclusions. Exact direct dictionary matches
bypass the beam. Constructed paths are bounded to the first 128 normalized
units and 4,096 output bytes. Final completions can extend up to eight
spelling units, with up to 32 direct completions per language. Composed
prefixes retain up to two distinct outputs per language combination and span.

Each edge adds a unigram or smoothed gram log probability in bits and
pays explicit spelling, token and language-transition costs. User
unigrams interpolate with the base prior. Base and user gram evidence is
interpolated from short to long histories during search, and a language
change resets the history. User evidence is bounded. Scores are heuristic
and use only the source consumed by each path. Whole results sort ahead of
prefixes, longer prefixes precede shorter ones, and score and stable
identity break ties within a span. The engine retains distinct languages
for identical output and keeps the exact literal last. The macOS app and the Rust CLI share this lexical scoring.
The app passes opted-in token and consumed-spelling preferences to the search.
Their larger value counts toward the shared 32-point frequency cap.

At composition start and after a prefix commit, `SIInputController` asks the
active InputMethodKit client for the full UTF-16 range before the insertion point.
It revalidates the client and ranges across the read. The Swift request carries
that text separately from composition spelling for both preview and full search.
It uses an empty context in secure input or when the host cannot supply the full
range. Direct input bypasses conversion. The snapshot is transient and local.

Rust selects the last sentence or unfinished sentence fragment from the supplied
text, including the last completed sentence after terminal punctuation. It uses
the lexicons to segment the sentence and keeps the final recognized same-language
word history up to the loaded gram order. The difference between the first word's
conditioned and unconditioned log probabilities adjusts ranking before pruning.
Language-start costs and subsequent composition scoring use their existing
histories. Candidates containing personal or verbatim segments receive no field
adjustment. The adjustment is separate from the lexical score saved by Personal Learning.

## Rust resource workflow

`si-cli` parses command-line arguments and prints import summaries.
`si-engine` owns resource loading, CSV and corpus imports, and snapshot
compatibility. It uses `si-lexicon` and `si-gram` for storage and lookup.
The macOS bridge loads the same artifacts through
`si_engine::resources::EngineResources`.

Lexicon imports accept one or more CSV files or directories, with a caller
selected lookup index for each. Directory CSVs are visited in filename
order. The compiler preserves exact text and reading, and sums `weight` for
repeated rows with the same text, reading, and lookup index. Different
readings of the same text receive separate IDs and counts. A zero-weight row
can add an entry with a count of zero. An empty or whitespace-only reading
fails the entire import and reports the source file and line.
Incremental imports append new word IDs and retain every existing ID.

Corpus imports stream explicitly selected pre-tokenized UTF-8 files.
Each nonempty line is a sentence, and whitespace separates tokens.
Tokens resolve by exact output text when there is one matching reading.
An ambiguous token requires `text|index|reading`, such as `重|0|chong`;
an unresolved reading fails the import. Unknown unannotated tokens are
counted in the summary and break the sequence. No gram crosses an unknown
token or a line boundary. The pre-tokenized import increments gram counts.

Builds require a new destination. Additions use the existing snapshot and
apply deltas once per command invocation. Keep source CSVs and tokenized
corpora separately for reproducibility. A sidecar lock serializes import
writes to each destination, and the binary snapshot is replaced only
after the entire import succeeds. Each dictionary has its own file, such
as `main.silex` or `user.silex`. Pair a gram snapshot with the lexicon that
assigned its word IDs. Incremental imports preserve existing IDs, so gram
snapshots remain compatible when words are appended.

[SI configuration](../config/si.conf) selects independent maximum counting
orders and vocabulary thresholds for base and user resources. Base corpus
commands use `[base]`, and user word-gram imports use `[user]`. Each import
counts new observations from order two through the selected maximum. It
preserves existing rows at every order when the setting changes. Paragraph
recovery publishes the staged result using the original batch's counts.

The engine reports aggregate corpus progress at file boundaries, periodically
while reading, and before building and saving gram tables. Byte progress
uses the current source file's size. The CLI displays progress on stderr
and the final summary on stdout. The stable sidecar file can remain after
exit. The OS releases its lock on process exit, including interruption.
Suspending a process keeps its lock until the process exits.

### Paragraph corpus import

`corpus ingest` reads explicitly supplied UTF-8 text, one paragraph per
nonempty line. The Rust segmenter indexes exact output spellings and chooses
the longest match from left to right using UTF-8 byte ranges. Matches end
at the boundary of a consecutive ASCII letter run. Unlisted runs of at
least two letters end the gram sequence. The importer groups them by
exact capitalization and exports `text,reading,weight` to
`<grams.sigram>.english.csv`. The reading is a lowercase lookup key and the
weight is the count from the latest batch. The file can be edited and imported
explicitly with `lexicon add` in English lookup index `1`. Single ASCII letter tokens and independent runs of
ASCII digits contribute `<char>` and `<num>` to the n-gram stream,
respectively. Each run of digits contributes one token. Exact compound
dictionary matches can include letters or digits. Placeholder IDs are
stored as unindexed zero-count symbols in the paired lexicon and reused by
later batches. The importer increments word counts for lexical matches.
An ambiguous Han match triggers contextual Pinyin conversion for the
contiguous Han run containing it. The segmenter verifies that the returned
characters align with the original UTF-8 spans, removes tone marks, and
compares the full reading with the lexicon, including SI's umlaut aliases.
It counts the match when the reading identifies exactly one existing entry.
An unresolved spelling consumes its full match and ends the gram sequence.
Unknown characters, unmatched punctuation, and paragraph boundaries also
end a sequence. Horizontal whitespace between tokens preserves adjacency.

The importer opens the specified lexicon and compatible word gram model,
or initializes missing snapshots. An existing model referencing word IDs
requires its compatible lexicon. Each batch increments counts in both files
at their original paths. Both locks stay held during preparation and
publication. The importer stages each replacement beside its destination,
then replaces the lexicon, gram model, and both review CSVs individually by rename.
Pending records beside the snapshots let the same command finish an
interrupted publication without recounting the batch. Other writes to
either snapshot are blocked while its record is pending. Failures before
publication leave existing snapshot files intact.

`corpus clear-grams` takes both snapshot locks and checks for pending
publication before deleting the gram file. The paired lexicon and review
CSVs remain available.

The review CSV at `<grams.sigram>.review.csv` groups unmatched and unresolved
segments from the latest batch by exact text and reason. It includes counts,
readable candidate keys from the lexicon, and each entry's first source path
and 1-based line number. The final `reading` column is blank on export.
`lexicon add` imports completed rows from this format and uses `count`
as the reading's count delta. It skips blank readings and leaves previously
counted grams intact. The review contains only the header when there are
no review items. Unix output permissions are owner-only. Import summaries
contain aggregate counts.

The shared Pinyin reader uses the [argsno Rust port of pinyin-pro](https://github.com/argsno/pinyin-pro-rust),
published on crates.io as `pinyin_pro` 3.29.4 at revision
`460d4802de044c71dd8305705028b5b60da82abd`. The crate embeds tables
generated upstream from zh-lx/pinyin-pro's TypeScript reading data.
SI builds the published crate directly using the Cargo lockfile.
The [included MIT notice](../crates/si-engine/licenses/pinyin_pro-MIT.txt)
covers the crate. MIT permits redistribution with the copyright and
permission notice and is compatible with SI's GPLv3 license. The locked
regex dependencies also offer MIT licensing. The reader runs locally
on the supplied corpus text.

### Lexicon CSV snapshots

`lexicon export` writes a full UTF-8 snapshot with the columns
`kind,id,text,weight,index,reading,key_hex`. A `word` row holds the
explicit ID, exact text, count, and optional primary reading. An `alias`
row holds an ID and an additional key without a separate count. Lookup
keys that cannot be represented as printable UTF-8 use `key_hex`.

`lexicon restore` reads the snapshot into a new `.silex` file. It restores
word rows in ID order, then binds aliases to those IDs. Word IDs are dense
ordinals starting at zero. Missing or repeated IDs, repeated word identities,
and invalid aliases fail before saving. Restoring the same ordered word
identities preserves compatibility with the existing word gram model.

Export uses an explicit destination and owner-only file permissions on Unix.
Existing destination files are preserved. Keep personal exports local and
delete them when no longer needed. The repository ignores files named
`*.silex.csv`.

### Chinese vocabulary discovery

The offline `corpus build --han` and `corpus add --han` commands count
overlapping windows of known Han characters through the base maximum order. These grams
use a separate character table keyed by written form for discovery.
Unknown Han characters, non-Han characters, and line endings break sequences. The Han
classifier uses the [Unicode 17.0 Unified_Ideograph property](https://www.unicode.org/Public/17.0.0/ucd/PropList.txt)
plus U+3007. The default corpus commands continue to take whitespace-separated
tokens.

`lexicon learn` reads the bigram table and validates the lexicon's
word-order checksum. It loads the Pinyin index and bigram thresholds from
[the `[base]` section of SI configuration](../config/si.conf). Each
candidate must meet the raw count floor. For a pair `L | R`, let `C`
be its count, `A` the sum of bigram counts starting with `L`, `B` the
sum of bigram counts ending with `R`, and `T` the total bigram count.
The forward share is `C/A`, the backward share is `C/B`, and lift is
`(C × T)/(A × B)`.
Each pair must meet all enabled thresholds. Denominators include
rows below the count floor and rows that cannot become entries. The
learner accumulates the marginals for candidates in a second pass over
the bigram table. Comparisons are exact and inclusive. A zero share or
lift threshold disables that check.

Both tokens must contain only Han characters and have a complete reading in
the selected full-Pinyin index, with one lowercase ASCII syllable per
character. Word models can supply multi-character tokens, and character
models supply individual characters. The learner concatenates the exact
token text and passes the whole new word to the shared `pinyin_pro` reader. The
reader checks that the syllables align with every original character,
removes tones and applies SI's umlaut aliases. The learner joins a
complete reading with apostrophes and adds it to the selected index.
An incomplete or invalid reading goes to the review CSV with an empty
`reading` and the original count. The caller can supply the reading and
import the edited CSV with `lexicon add`.

The qualifying raw count from the gram table becomes the new entry's initial
count. An existing output in the selected index retains its IDs, counts,
and keys, including readings supplied through review. Rerunning
learning adds no duplicate words and can export pending words again. The
learner writes a fresh numbered CSV beside the lexicon before saving any
lexicon additions. It holds the lexicon's existing write lock throughout
and leaves the gram file unchanged. The character model can be retained
for discovery. To count
sequences of the learned words for ranking, tokenize the corpus with the
expanded vocabulary and build a separate word gram model.

The workflow reads only explicitly provided files. Keep the seed inputs to
rebuild or discard a learned lexicon. Delete the derived snapshot, review
CSVs, and gram files to remove those local artifacts. Review CSVs use
owner-only file permissions on Unix. The repository ignores review files
generated beside `.silex` snapshots. This workflow is independent of the app's
Personal Learning and Input History.

## Rust user model

`UserModelStore` takes supplied sentences and a read-only base
lexicon. One forward maximum-matching index combines the base lexicon and
the user's current entries. Identical text, lookup index and primary reading
resolve to one lexeme. Contextual Pinyin disambiguates known Han readings.
The profile allocates its own word IDs and increments only its own counts,
including for matches found in the base. New English runs preserve case and
use lowercase lookup keys in index 1. A Han character outside both lexicons
uses a derived reading when available. Spaces preserve word adjacency.
Punctuation, numbers and unresolved text end a word-gram sequence, as does
each sentence boundary.

An independent Han-character bigram table tracks adjacent characters
regardless of word boundaries. User learning applies its own occurrence,
directional-share and lift thresholds, skips existing Chinese words, and
adds two-character words with complete Pinyin readings. A newly learned word
starts with its observed character-pair count and participates in later
segmentation. Earlier word grams retain the segmentation used when imported.
Base and user snapshots can be loaded together as independent
`EngineResources`, each with its own lexicon-to-gram ID mapping.

The profile serializes updates with a stable lock. It writes the paired
lexicon and gram snapshots, character evidence and batch receipts into an
inactive generation. One atomic pointer change publishes the generation.
Readers load the selected pair under the same lock. An interrupted write
leaves either the previous generation or the fully published generation
readable. A repeat batch ID prevents recounting, and the next update
removes any inactive generation. Clear publishes an empty profile and
deletes both generations. Only derived words, counts and opaque batch IDs
are retained. The `.si-user` directory is ignored by Git.

## Rust lexicon

The standalone Rust workspace includes an editable, language-independent
lexicon. Callers open each dictionary by path and choose which numbered
indexes to query within it. An index accepts opaque byte
keys. Spelling normalization, enabled languages and candidate ranking belong
to the caller.

Each lexeme consists of exact UTF-8 output text, a primary reading, and its
lookup index. A word ID is a 32-bit ordinal assigned on first insertion
within that file. The same ordinal can refer to different words in two files.
Reimporting the same lexeme increments its checked 64-bit occurrence count
and retains its ID. An explicit alias can add a lookup key for that ID.
Text-only lookup resolves a single entry and can enumerate all entries when
the text has multiple readings. IDs survive compaction and snapshot reload.
Edit an existing snapshot to preserve its IDs across versions.

Packed snapshots store UTF-8 text, primary readings, and key bytes in
contiguous buffers.
Offsets and postings are 32-bit integers. Exact lookup binary searches sorted
keys and reads their contiguous postings. Prefix lookup starts at the same
lower bound and streams matching postings in key order. Edits are searchable
immediately. Compaction folds them into the packed index. File loading
validates section lengths, UTF-8 boundaries and index order, then keeps the
packed arrays in memory for queries.

Saving writes one versioned snapshot at a caller-selected path. It replaces
the previous file after writing and syncing a sibling temporary file, with
owner-only file permissions on Unix. Use one writer per dictionary file.
A caller may keep a separate file for user-added words and delete that file
to remove the entire dictionary. The library does not select a storage path,
record typing, or manage the installed app's Personal Phrases or Personal
Learning stores.

The benchmark measures synthetic construction, compaction, file size, warm
open, exact and prefix lookup, ID lookup and additions to an existing
dictionary. Reported query percentiles are computed over batch averages.

## Rust gram model

`si-gram` stores raw 64-bit occurrence counts for ordered sequences of two
through five words. The builder accepts pre-counted grams or counts every
overlapping window in a pre-tokenized sequence. Call the builder separately
for each sentence or other boundary. Importers supply tokenization and
`WordId` values from one lexicon file per model.

The model keeps a sorted key table and a count array for each order.
A small in-memory directory uses the first word ordinal to narrow each exact
lookup. For repeated candidate queries, a prepared context borrows the
contiguous rows for one history and looks up each next word within those
rows. Both lookup paths allocate no heap memory.

A `.sigram` snapshot uses four bytes per word ID and eight bytes per count.
Version 4 stores the highest serialized order and the row count at each
order in its header. Snapshots with five-grams use version 4, and snapshots
through order four retain the earlier layout. CLI-generated gram files
record a checksum of exact text, primary reading, and lookup index in
ordinal order through the largest referenced ordinal. The engine uses it
to detect a mismatch even when two entries share the same text. Appending
words, changing counts, and adding aliases preserve the pairing.
Opening the file validates its length, key order, and counts, loads the
arrays, and rebuilds the lookup directory. The Rust
benchmark measures snapshot size, warm open, exact hits and misses, and
queries with prepared histories on synthetic data.

Offline pruning filters rows below a caller-supplied count in one order.
It validates the paired lexicon before filtering, rebuilds the affected
lookup directory, and refreshes the pairing checksum if the referenced
lexicon prefix shrinks. The engine uses the corpus writer lock and existing
snapshot replacement path to publish the result.

Version 1, 2, and 3 files remain readable. An older dictionary entry with one
lookup key can recover that key as its primary reading. Entries with
several keys retain their historical aggregate for lookup. Rebuild from
the original CSV to recover individual reading counts. Older gram files
must be paired with their original lexicon. Rebuild old character models
with `corpus build --han` before adding more character observations.

## Interface localization

`mac/SI/Localization/Resources/{en,zh-Hans}.lproj/Localizable.strings` provides the same English source keys and Simplified Chinese translations to SwiftUI and AppKit. The app uses the main bundle and native macOS app-language negotiation, with `en` as its development language. SwiftUI literal labels use native localization; `L10n` resolves dynamic labels, errors and format arguments. The package builds the same helper/resources as `SILocalization`, using `Bundle.module` for tests. Language changes take effect on a normal process restart; no extra language preference, input mode or keystroke shortcut is introduced.

Localization stays outside `SICore`. Stable language identifiers, core display-name/label metadata, candidate identity, ordering and exact commit bytes are unchanged. Settings localizes the core language/punctuation descriptions at presentation; `CandidateDescription` derives localized candidate labels from structured metadata. User text, phrase codes, application names/identifiers and archive contents are never treated as translation keys. E/C/A punctuation badges keep their existing identifiers while tooltips and accessibility descriptions are translated. No input or personal data is added to localization resources.

## Composition state and presentation scores

`InputSession` owns the buffer, character-aware caret, and candidate request
for each client. A deferred edit immediately retains the exact literal.
The session accepts results for the current request and rejects a preview
after full results. Explicit selection can commit an already displayed
preview. Prefixes consume validated source boundaries and keep the exact
remainder editable.

Swift combines Rust's lexical scores with eligible preferences and a
coverage reward for the consumed source. Complete candidates precede
prefixes. Within a prefix span, candidates compete by score. The same
bridge and session code runs in the app and SwiftPM tests.

`PunctuationCandidates` supplies a fixed local table of English/Chinese alternatives for common ASCII punctuation. The shared engine includes these alongside direct provider and personal matches only when its explicit punctuationCandidatesEnabled option is enabled; this option defaults to false. Exact literal spelling is retained. A single trailing mark can be attached to complete word/sentence choices from the same engine; partial and incomplete choices are excluded. Repeated trailing punctuation does not recurse or expand combinations. Apostrophes after existing input retain their syllable-boundary meaning. `InputCandidate.punctuationLanguage` distinguishes punctuation variants independently of a preceding word's language and participates in cached identity. Explicit isPunctuation metadata also marks the literal fallback for badges and acceptance-spacing behavior, rather than inferring the enabled feature from its text. These variants inherit personal/verbatim exclusions, carry no automatic-confirmation evidence, never train vocabulary/context and never append an acceptance space. Constructed output remains bounded to 4,096 UTF-8 bytes. Full and provisional generation share this path; original input and stale-result validation remain unchanged.

With Show punctuation candidates and a language enabled, the controller starts marked composition for mapped punctuation even when the buffer is empty. The switch is off by default; when off, all punctuation outside composition passes through. Other symbols pass through outside composition. During composition the existing `PunctuationBehavior` policy still decides whether a key remains editable or confirms a candidate. Compact and expanded rows show small E/C badges immediately after punctuation text, with A for the As Typed literal fallback; tooltips and accessibility retain the full description. Badge letters use Core Text glyph-path bounds to center their visible ink horizontally and vertically, independently of NSTextField baseline padding. Only the selected text is committed.

## AI completion

Ordinary candidate updates never invoke AI. `AICompletionTabAction` routes a plain, nonrepeated Tab during composition to one request; while busy it consumes further Tabs, and when a valid suggestion is ready it routes Tab to acceptance. `SIInputController` suspends automatic confirmation for the manual request, verifies the IMK client against the foreground app, and captures available bounded IMK field text. AX APIs and app allowlists are absent from the prediction path.

`AICompletionScreenshot` selects an on-screen window belonging to the foreground input app. It prefers the IMK client's reported level, then the frontmost normal window, then another visible window of that same app, retaining the actual Window Server level and ID for validation. It checks Screen Recording consent without prompting, captures only that window using ScreenCaptureKit's desktop-independent window filter, caps the longest image edge at 1,600 pixels and PNG size at 8 MiB, and rechecks the window after capture. Missing Window Server matches, absent shareable windows and ScreenCaptureKit errors have distinct messages; framework failures retain only the NSError domain/code, without window titles or content. The controller also rechecks client, consent, secure/direct input, composition, selection, available field text and window identity before dispatch, delivery and acceptance.

Codex receives an owner-only temporary PNG via `--image`, deleted on completion or cancellation. Claude receives a base64 image block through stream-JSON stdin, and OpenAI receives an `input_image` data URL alongside text through the Responses API. All use 30-second prediction timeouts. API and Claude screenshot data stays in memory. Forced process termination or a filesystem failure may leave a Codex temporary file until the OS cleans its temporary directory.

CLI requests launch `Process` directly with no shell or terminal and `/private/var/empty` as the working directory. `AICompletionCLIEnvironment` retains basic process identity/locale, backend-specific authentication and a bounded list of network configuration variables: uppercase/lowercase `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY`, `NO_PROXY`, plus `SSL_CERT_FILE`, `SSL_CERT_DIR`, `CURL_CA_BUNDLE`, `REQUESTS_CA_BUNDLE`, `NODE_EXTRA_CA_CERTS`, `NODE_USE_SYSTEM_CA` and `NODE_USE_ENV_PROXY`. Proxy credentials remain in the child environment and are never logged. The executable's directory precedes inherited absolute PATH entries and standard installation directories.

On each CLI request, CFNetwork's system proxy dictionary supplies enabled static HTTP/HTTPS/SOCKS addresses and bypass exceptions when corresponding explicit environment settings are absent. An explicit `ALL_PROXY` or `all_proxy` suppresses all system proxy fallback; explicit per-scheme values, including empty strings, are preserved. SI does not read shell startup files, fetch/evaluate PAC scripts, perform WPAD discovery or retrieve system proxy passwords from Keychain. The selected CLI determines which proxy schemes, bypass syntax and certificate variables it supports. The direct OpenAI API adapter continues using URLSession's default system proxy handling.

The nonactivating second row reports progress or the candidate plus a bounded suffix. A second Tab or explicit click commits the text once using `aiCompletion`; the independently opted-in Input History may save the actual submission. AI text does not train vocabulary or change ranking. Settings preserves the latest status using request IDs, without retaining screenshot or input data in diagnostics.

## Candidate presentation

`MarkedTextPresentation` projects the session's exact buffer into host marked
text using source-character cuts from the highest-ranked whole nonverbatim
candidate. Chinese lexical traces carry source-only syllable cuts separately
from output-aligned confirmation evidence; English trace nodes delimit words.
Incomplete direct Chinese readings retain their typed cuts as display metadata
without creating confirmation evidence. The projection inserts visual spaces,
preserves original bytes/casing/apostrophes, and maps the character caret to the
displayed UTF-16 offset, including those spaces. The controller uses that offset
for the marked selection. Editing, commits, learning and history continue to use
the original session buffer. Pending searches have only current
literal spelling until revision-checked hints/full results supply segmentation;
identical marked text/selection is not resent. Prefix-only candidates do not
invent segmentation for an unconsumed remainder.

`CandidateSelection` owns one client-local engine shortlist, selected index and
page. Compact rendering shows one numbered row; Down expands the same ranking
into a grid. Space, numbers and mouse clicks confirm the same candidate IDs, and
the displayed global first choice stays neutral for Personal Learning. Pending
engine searches disable stale rows until revision-checked results arrive.

## Automatic prefix confirmation

`LanguageSettings` persists a separate, initially disabled automatic-confirmation option. Its in-process configuration generation also changes when languages or punctuation/confirmation settings change, invalidating evidence even if a setting is toggled away and back between input events. Secure event input disables the option at the controller boundary independently of learning consent.

When enabled, full `CandidateRequest` generation captures transient `ConfirmationBoundary` evidence from the existing lattice: exact source-character counts (including ü/u: normalization and trailing separators) and cumulative output UTF-8 byte counts at up to eight leading, exact Chinese lexical nodes. Immutable shared trace tails bound per-path evidence without copying boundary arrays on each expansion. Capture stops at abbreviation, completion, personal, verbatim or English edges; full results retain earlier exact boundaries. Capture is disabled for provisional searches and ordinary engine callers. Evidence does not affect identity, scores, pruning, lexical presentation or output bytes.

On the background worker, `AutomaticConfirmation.prefixes` compares the leading whole Chinese candidate with every whole alternative within three ranking-score points, including eligible other-language competitors. This is a relative-score band, not a calibrated confidence probability. A proposed prefix must have identical committed bytes and source/output boundaries on every competitor; no textual-prefix or syllable-count guess substitutes for alignment. Mixed/personal/verbatim leaders, uppercase spellings, malformed output boundaries and non-Pinyin symbols do not produce proposals. An exact English word of at least four letters starting at a leading Chinese lexical boundary also suppresses proposals, independently of enabled languages; this protects tails such as `title` from being treated as Chinese-only spelling. Explicit syllable separators constrain this check. Literal fallback remains present but is not statistical evidence against every conversion.

`InputSession` retains at most eight client-local prefix observations. Only accepted full results advance stability, once per distinct appended spelling; pending, provisional, stale and cross-session results cannot confirm. Continuous confirmation requires two observations, six additional source characters since the first observation, at least four remaining output characters and eight remaining normalized letters. Pause confirmation requires at least 1.8 seconds since input, 0.6 seconds since the observation, a prefix of at least two output characters, two remaining output characters and four remaining normalized letters. Both use the same consensus proposals and complete lexical boundaries. Editing/navigation suspends evidence; only fresh end-of-buffer typing can restart it. Configuration, reset, commits and host boundaries invalidate evidence and the timer revision. A prefix commit resets observations, so a timer cannot repeatedly drain a stationary composition.

`SIInputController` attempts continuous confirmation on accepted result delivery. Its single cancellable, weakly captured main-actor pause task rechecks session revision, current client, settings and secure input before the same `automaticallyConfirm` method. Neither path synchronously resolves a search. `.automaticConfirmation` has zero learning weight. The ordinary prefix commit/marked-remainder path handles insertion exactly once without an English space and refreshes the local field context after insertion. Already committed text uses ordinary host editing; there is no cross-host automatic reconversion/undo contract. Native focus/timer delivery remains an integration check.

## Personalization and storage

`ApplicationMemorySettings` is the global entry point for learning settings. The retired global `PersonalizationSettings`, its Settings views and `LearningStore` are removed from the app and package. Launch/termination prepare or flush app memory, explicit phrases and the independent Input History store; input uses a shared global profile when learning is enabled and input is not secure. Disabled or secure clients use base ranking. No disk I/O or dictionary initialization runs in the keystroke handler.

The UI-independent `LearningProfile` and `LearnedPreference` models remain shared ranking primitives for Personal Learning. Single-language frequency records can influence whole/prefix and eligible internal tokens before bounded limits, preserving base/personalized search beams and the shared 32-point cap. Chinese single-character outputs do not transfer into other compositions. Core contextual-ranking/session APIs remain available to library fixtures, but the application does not enable, store or expose previous-word pair learning. Old global archive schema versions are no longer loaded or migrated.

`PrivateArchiveFile` shares regular-file validation, bounded reads, owner-only permissions, atomic replacement and erase mechanics across the remaining storage actors. App memory provides an actor-isolated existence/deletion operation for the retired `preferences-v1.json` path without decoding its contents. Settings exposes explicit deletion with independent progress/error feedback. Old consent flags are ignored and removed only with that deletion. Existing files are not erased or assigned to guessed app scopes; the inactive old archive receives no automatic retention maintenance.

`UserDictionarySettings` owns the separate explicit phrase dictionary and uses `UserDictionaryStore` for local persistence and file import/export preparation. JSON imports validate all phrases, merge into a copy, preserve existing content/pin settings, and apply only if no intervening edit/clear changed the revision. Capacity errors leave the entire import unapplied. Storage and import/export errors remain distinct so a later successful save cannot hide a failed import. Phrases retain until explicit deletion, independent of learning. Cached code/identity indexes support direct full/prefix matches and intermediate lattice nodes; any derived path containing a personal node is excluded from automatic learning and prior-word context.

### Personal Learning

`ApplicationMemory` contains global `ApplicationVocabularyEntry` records keyed by normalized consumed spelling, language/mixed identity and output, without application identifiers. Each record retains a noncontextual `LearnedPreference`, aggregate use/correction counts, base score, lexical-unit evidence and optional latest deliberate-selection time. Every eligible confirmation increments usage; only explicit nonfirst choices update the remembered choice and correction count. Every third correction still adds one frequency point, up to 32, stored as `exp2(bonus / 12) - 1`. `LearningProfile(retainsIndefinitely: true)` disables age expiry and strength decay for this product profile; the default library policy remains available for historical fixtures. Zero-strength usage-only rows inject no candidates; one correction can inject its saved candidate immediately. Literal, personal/verbatim, punctuation and automatic/delimiter commits never train. No sentence-token decomposition is saved.

`InputSession` owns a bounded `CompositionLearning` accumulator for successful manual prefix confirmations while Personal Learning is eligible. The controller acknowledges each fragment only after insertion and client, consent-generation and secure/direct-input revalidation. Exact consumed source and submitted candidate bytes are joined only when the unchanged remainder is fully confirmed; base scores and lexical counts are summed without scoring hypothetical suffixes. The completed aggregate is additional vocabulary evidence, never a second host insertion or Input History event. Individual fragment learning remains unchanged. Any nonfirst selection supplies whole-spelling correction evidence; all-first sequences stay neutral. Edits, reset/focus/context or relevant configuration changes, disabled/secure learning, failed insertion, source mismatch, size overflow and literal/personal/verbatim/punctuation/automatic/delimiter/AI fragments discard the aggregate. The temporary state stays per client, has no disk/network path, and uses existing schema-4 records and deletion/capacity rules after completion.

A bounded spelling-to-record index maintains one latest deliberate choice per normalized spelling. A new correction clears the former choice's selection marker, even when wall-clock timestamps tie, without deleting its aggregate counts or frequency strength. `ApplicationMemorySnapshot.preferredCandidateID` resolves the whole normalized input against enabled languages. The shared engine's final and provisional merges place this ordinary whole candidate after explicit personal pins and before score-ranked alternatives, leaving all other candidates in their deterministic score order. Prefixes, shorter spellings and longer inputs never gain forced placement. A prefix confirmation can supply the remembered choice only when its consumed spelling is subsequently typed alone. Exact literal input remains explicit and language-aware identity is unchanged. Forgetting a selected entry restores ordinary ranking, without reviving an older selection marker.

`ApplicationMemorySettings` owns default-off global learning consent and one cached immutable snapshot. Learning settings/snapshot/record APIs have no app parameter or exclusion list. The retired `applicationMemory.vocabularyExclusions` key is removed without changing existing learning consent. The controller still reads the actual IMK client's bundle identifier for the independent direct-input rule and focus/reentrancy checks; learned records do not retain it. Disabled, direct-input and secure clients neither record nor use the global profile. Client/settings revisions continue to reject stale candidates, clicks and automatic-confirmation tasks. `CandidateSelection.confirmationReason` compares against the displayed first candidate after font filtering/shortlisting; Space, number, mouse and navigation back to the first candidate stay neutral. First cells on later pages remain nonfirst. Punctuation's safeguards remain separate.

`ApplicationMemoryStore` performs actor-isolated I/O at the existing `SI/Personalization/application-memory-v1.json` path, with vocabulary-only schema 4, a 64 MiB file limit, owner-only permissions, atomic replacement and revision-ordered saves/deletion. Schemas 1–3 migrate atomically, stripping app identifiers/history and merging equal record identities: counts are summed with existing one-million caps, latest usage/base metadata is retained, and strength uses the maximum rather than stacking app bonuses. Schema-1/2 mixed default/correction evidence resets to neutral; schema-3 strength/corrections survive. No old schema supplies an exact-choice marker because it lacks a deliberate-selection timestamp. Age alone no longer invalidates retained records. Malformed/unsupported archives remain untouched; migration write failures propagate and pause loading. The retired `preferences-v1.json` archive is never decoded or imported and keeps its explicit deletion control.

Vocabulary retains at most 5,000 records; capacity eviction removes least recently used entries with identity tie-breaking. There is no timed expiry, decay or daily expiry task. Saves coalesce for 300 ms and flush on normal termination. Settings provide global search, Forget and global clear/archive erase under **Personal Learning**, with no application picker, pause or app discovery. Existing learning consent persists; old history flags never grant learning consent. The former App History draft/completion feature and previous-word pair learning remain absent. The separate Input History below does not provide candidates. Candidate-choice learning uses confirmed SI text. The independent sentence learning switch controls the bounded Return-time host read below.

### Input History

`InputHistoryEntry` is a core value for one submitted composition: UUID event identity, timestamp, exact consumed source/output, optional language, mixed identity and commit reason. `SIInputController.apply` captures independent history consent/secure state and generation before calling the host's `insertText`, then rechecks the returned insertion/reentrancy boundary, client/direct-input policy and history consent before enqueueing the record. Candidate, literal, personal/verbatim, punctuation and automatic-confirmation submissions are eligible; empty commits, cancellation, marked edits and passthrough keys outside composition never create a row. Prefixes use `InputCommit.input`, excluding its remainder; actual SI-inserted suffixes are included in output. This captures SI's insertion contract, not a readback/acknowledgement of the host document. No host text is queried.

`InputHistorySettings` owns independent default-off `inputHistory.enabled`, a serialized task chain, bounded displayed pages, consent/storage/read generations and in-memory failed-write retry entries. Personal Learning and all retired consent keys cannot enable it. The key handler only creates a value and queues work. Save errors pause new recording and retain accepted failed entries for explicit retry; turning history off keeps previously accepted writes/data. Clear advances the storage/consent/read generations, stops recording until completion, discards pending retry records and serializes database removal after in-flight writes. Older queued inserts skip obsolete epochs. Entry deletion follows prior writes and removes that event from pending retries, so retry cannot resurrect it. Read generations reject late search/page results. Normal app launch prepares the history actor alongside other stores; termination awaits its queued work.

`InputHistoryStore` uses the system SQLite library. Schema 1 lives separately at `SI/InputHistory/history-v1.sqlite3`, under 0700 directory/0600 file permissions with DELETE journaling. Each operation opens/closes its actor-confined connection; prepared SQL binds text with explicit UTF-8 lengths (including embedded NUL), and retrieval uses byte counts rather than C-string termination. UUID uniqueness makes retries idempotent while preserving repeated real submissions as distinct events. Append batches use transactions. There is no age/count eviction, full-archive rewrite or full in-memory load: newest-first pagination uses monotonic SQLite sequence cursors, returns at most 100 entries plus lookahead, and remains stable when newer events arrive or the wall clock moves backward. Search binds literal source/output substrings with ASCII case folding; no query/input text appears in error logs. Explicit row deletion uses secure_delete; explicit clear removes the database and journal/WAL/SHM sidecars, including corrupt/unsupported archives. This is not a guarantee of forensic erasure or backup deletion. Corrupt/unsupported opens preserve existing bytes. History is unencrypted and independent of learning/phrases/retired files, with no migration, ranking, completions, automatic training or network path. User-controlled export and offline preparation follow the separate workflow below.

### Sentence learning

The `sentenceLearning.enabled` switch defaults to on when no preference is saved and requires global Personal Learning. A successful manual lexical confirmation arms one nonrepeated Return with empty composition. The controller excludes secure/direct input and invalidates eligibility across client, focus and consent/configuration changes. `SentenceSnapshotReader` validates the selection, marked range, reported text length and exact returned UTF-16 length. It rechecks client and consent across host calls. The controller forwards Return normally. The complete single-line input is read before the app handles the key.

`SentenceLearningSettings` keeps at most 32 queued lines and one in-flight or retry batch in memory. The actor calls the same `UserModelStore` ingestion and word discovery used by the CLI, then loads the paired user resources into a new immutable Rust decoder sharing the existing base resources. The Swift snapshot carries that decoder only for eligible requests. Existing request IDs and settings generations reject obsolete conversion results; clear drops pending samples and runs behind in-flight ingestion. The retired raw SQLite archive is never opened or migrated. Settings offers explicit file/sidecar deletion, and offline extraction still accepts older exports.

### Portable history export

`InputHistoryExportButton` opens `NSSavePanel` directly with one user-selected `.jsonl` destination and a private-data disclosure. There is no purpose chooser or training-permission flag; exporting does not change recording consent or send data. `InputHistorySettings.export` joins the existing serialized mutation queue so previous writes settle and normal termination waits for the export. Pending failed writes block export. Export success/error state is separate from recording/storage errors. The same action appears in the Settings section and paged history manager; search and current pages never limit the export.

`InputHistoryStore.export` streams one consistent SQLite read transaction in ascending native sequence order. The UTF-8 JSONL manifest declares format/version/scope/export time; each entry preserves original sequence, UUID, raw source/output, Unix time, language/mixed identity and reason. A summary contains total count and CryptoKit SHA-256 of exact preceding LF-terminated lines. A 64 MiB per-object bound applies to the portable format, with no total-file/count limit. No normalization, aggregation, inferred labels, user/device metadata or automatic transfer is added. One 0600 temporary file is written beside the destination, synchronized/closed and atomically renamed; failures preserve the prior destination and remove temporary files. The live database/sidecars cannot be overwritten as export targets. Clear/delete after a snapshot does not erase its external copy.

`scripts/input_history.py` validates all schema/type/sequence/UUID/count/hash constraints while restoring rows into a private temporary native schema-1 SQLite database. Completed restores publish to a new path without overwriting existing files. The same ordinary export can be restored or produce `input,target,language` candidate CSV/provenance, preserving observations and excluding automatic/passthrough/literal/unknown-language rows by default. Optional ASCII literal tasks require an explicit flag. No maintained train/validation/test sources, tensor preparation, runs, weights, remote storage or app history are changed by these commands. Metadata tracks archive/CSV hashes and filter counts and unsplit/unreviewed status; no sample text is printed. The format and review boundaries are in [INPUT_HISTORY_EXPORT.md](INPUT_HISTORY_EXPORT.md).

## macOS integration

`LanguageSettings` persists an initially empty set of direct-input application bundle identifiers and advances its existing configuration generation when a rule changes. `ApplicationDiscovery` scans standard Applications folders and explicit/running app URLs on an actor only while the Settings manager loads or refreshes. It reads bundle metadata, skips nested app helpers, and deduplicates by identifier. Discovered bundle URLs stay in memory for row-local `NSWorkspace` icon loading when a row appears; paths and icons are not persisted. Missing apps use a generic application icon. The manager retains missing enabled identifiers for removal and supports manually selecting apps elsewhere. Discovery and icon loading never run in key handling or read input/document text.

`SIInputController.configureSession` checks the actual IMK client's identifier before configuring conversion and returns false for direct input. Key handlers then return false before interpreting letters, candidate numbers, punctuation, Return or navigation. Mouse selection, page/expansion actions, candidate delivery, composition callbacks and automatic-confirmation timers recheck the same boundary. Entering direct input resets the session, invalidates both pipelines, clears selection/presentation, and inserts any exact pending spelling once through the existing insertion path without learning or a suffix. An already-running search cannot restore the reset session. Rules do not change enabled languages or the registered input source. They cover an entire app rather than particular browser tabs, DOM fields or editor panes. They suppress vocabulary recording and use, without deleting existing data or modifying consent.

`LanguageSettings` also persists the Direct Input shortcut (default Control–Shift–I, physical key code 34). `SIInputController` matches it before the direct-input guard and ordinary shortcut passthrough, using the event client’s bundle identifier. Repeated matches are consumed without toggling again; secure input and unknown clients do not toggle. Rule changes reuse the existing configuration/reset boundary. Settings records modified printable keys in a sheet-local first responder, supports cancellation/reset, and never installs a global event tap or monitor.

`ExperimentPermissions` uses a lazily created PermissionFlow controller for the two explicit Settings actions. Each action opens its own Privacy & Security pane and offers the running `Bundle.main.bundleURL` for the user to drag into the system list. PermissionFlow tracks the System Settings window for panel positioning and falls back to Window Server bounds when Accessibility trust is unavailable. SI disables PermissionFlow's optional Accessibility prompt and uses `AXIsProcessTrusted` and `CGPreflightScreenCaptureAccess` for nonprompting status checks. The app target pins PermissionFlow 2.11.4 and bundles its MIT notice. The shared Swift package has no PermissionFlow dependency.

`SIApplication` starts an AppKit application. `AppDelegate` retains one `IMKServer` for the process lifetime. `mac/Support/Info.plist` names the connection and the stable Objective-C controller class `SIInputController`; it declares a background input method with one input source and no mode dictionary. The bundle and source identifier is `com.caterm.inputmethod.si`, including the `.inputmethod.` segment used for InputMethodKit discovery. `TISIntendedLanguage` is `en` so SI is discovered under English; its character repertoire still includes Latin and Simplified Chinese scripts. This system classification does not choose an active language inside SI. Showing Settings changes the process activation policy to accessory so the background declaration does not prevent displaying the settings window.

The local installer builds Release by default (`./scripts/install.sh Debug` explicitly opts into an unoptimized debugging build). Before building, it requires a unique valid Developer ID Application identity from the Keychain code-signing policy, optionally selected by `SI_SIGN_IDENTITY` (certificate name or exact SHA-1 fingerprint). It signs nested code and the staged app with that certificate and verifies the bundle before replacement. Missing/ambiguous identities and signing errors abort without an ad hoc fallback. No personal identity is stored in the repository. Local signatures omit secure timestamps and do not submit notarization requests; the designated requirement still uses the Developer ID identity rather than a per-build code hash. Changing signing identity/channel can require renewed privacy authorization, which remains managed by macOS. It calls `TISRegisterInputSource` after installing the signed bundle, then queries only SI's bundle ID (including disabled sources) and requires exactly one selectable keyboard input method. It never enables/selects an input source. `--check` performs only the verification query. Existing `com.caterm.si` installations are replaceable by the installer without retained backups. The local installer holds the old bundle in temporary staging for replacement-failure rollback, then removes it on success. `SettingsDefaults` deliberately retains the original `com.caterm.si` domain for language, punctuation, and learning consent; archives remain at their existing Application Support paths. No consent is reset or inferred by the bundle-ID correction.

`scripts/reinstall.sh` explicitly opts into stopping the current user's exact-name `SI` processes with SIGTERM, waiting up to five seconds before SIGKILL and another bounded wait. It then delegates to the installer, retaining both running-process checks and temporary rollback without retained app backups. A restarted process can still cause installation to abort. It does not select/enable input sources or force logout; pending composition and unsaved learning may be lost when stopping SI.

`SIInputController` adapts key events to the core and maintains marked text in the client. It owns one `CandidateSelection` and one nonactivating AppKit `CandidatePanel` per client. Number labels, highlighted rows, arrow/page navigation, Space confirmation, and mouse clicks use the same selection/page state. A composition starts collapsed, with six choices per horizontal page; expanding displays one page of four rows, up to 24 choices. Switching layout preserves the selected candidate and digit while recomputing the page; ending the composition resets expansion. Row labels remain presentation data; only validated candidate text is committed. Objective-C callbacks lack Swift actor annotations. The UI callback boundary uses `MainActor.assumeIsolated` explicitly; this relies on InputMethodKit delivering those callbacks on the main thread. Non-Sendable Objective-C callback arguments are captured using narrowly scoped `nonisolated(unsafe)` locals, and the controller explicitly declares `@unchecked Sendable` while its mutable state stays main-actor isolated. This boundary must be exercised during manual integration checks.

`MarkedTextState` suppresses repeated host updates when the exact composition bytes and UTF-16 selection have not changed. Provisional/final candidate deliveries update the panel without restarting identical host marked text. Edits, caret movement and cancellation still send the required update; commit, deactivation and client changes clear the cache. Async delivery also checks the active client before updating the session. Identical visible candidate identities retain their row views; unchanged row configurations avoid label/accessibility writes. Changed identities still replace rows so removed controls cannot confirm replacement text. Panel resizing finishes layout before display. These remove redundant refresh paths; automated state/view checks do not prove that a reported transient system window is eliminated.

Candidate panels additionally share one weak main-actor visibility owner. Activation or a current key event claims that owner and hides the previous panel; result delivery, timers, mouse callbacks and panel rendering cannot reclaim it. A late old-client deactivation cannot release a new client's owner. This shares only presentation ownership, never composition buffers or selection. The `activateServer:` override uses the existing main-thread IMK callback assumption, checked against the SDK declaration; actual callback ordering remains a native integration check. Per-controller presentation revisions also reject work superseded by synchronous reentry during host marked-text, insertion and geometry calls. Geometry resolves on a local value copy to avoid overlapping mutation of controller anchor state during such reentry.

`CandidateSelection` applies `CandidateTextSupport` before shortlisting both provisional and full results. Core Text shapes each grapheme with the same system font as `CandidateRowButton`, including system fallback; a LastResort run or glyph zero excludes the entire nonliteral candidate. Exact literal input bypasses the filter. A bounded, client-local cache keys coverage by exact UTF-8 grapheme bytes and clears when composition ends; no text is saved or logged. Filtering before shortlist allocation lets supported replacements compete for the same ranked head and ordinary budget. Numbers, Space, paging and mouse selection all use the filtered list. The shared engine, dictionary, scores and automatic-confirmation evidence are unchanged; offline quality shortlists do not model machine-specific font coverage.

`InputCandidate.lexicalTokenCount` carries transient lexical evidence independently of identity, score and commit text. Deduplication preserves single-lexical-unit evidence when a stronger composed derivation shares an identity. `rankingScore`/`inputScore` retain base lexical scores; `InputSession.presentationScore` adds learning/context and the consumed-input coverage reward used by `CandidateEngine.merge`. Keeping coverage outside the decoders leaves same-span terminal/prefix beam selection and automatic-confirmation evidence unchanged. Prefix preferences retain their full capped bonus and never use pending spelling. Punctuation variants embed only the prefix's lexical/preferences score, so coverage is added once during their own merge. Exact personal pins retain their explicit override.

`CandidateShortlist` supplies a 27-choice ordinary budget including exact literal input, plus independently pageable generated Chinese dictionary characters. Only the first four ranked choices may contribute constructed sentences or multiword fragments, across Chinese, English and mixed candidates. Remaining ordinary capacity is filled with single lexical units, explicit personal phrases and punctuation choices; mixed/verbatim spans do not qualify as ordinary word choices. Words already ranked in the leading four keep their own positions rather than causing lower sentences to be promoted. Every retained nonliteral candidate keeps engine order, with no language reservation; the literal remains last. Font filtering precedes the budget. Compact/expanded pages, numbers and mouse actions use the same client-local shortlist. Base lexical scores, coverage rewards, search bounds, committed bytes and candidate identities are unchanged by this presentation restriction.

The controller consumes navigation and number-selection events while composing. `CandidateSelection.action` maps the first Down Arrow while collapsed to expansion without advancing selection, and otherwise maps event key codes/characters to moves or numbered choices; digit lookup reads the active six-column row, while the expanded view renders one four-row page. Left/Right selects in the collapsed strip and changes columns when expanded; expanded Up/Down changes rows. These grid moves clamp within the current page. Page Up/Down and footer buttons use the current page capacity (six or 24), preserving position where possible. There is no `IMKCandidates` instance or dependency on its selection-key display, identifiers, or callbacks. Out-of-range row numbers do not commit another candidate. Shortcuts retain literal passthrough, and outside composition these keys pass through. Candidate edits/reset invalidate the previous selection. Mouse buttons return candidate identities and use the same current-candidate validation/learning path as digit keys.

The panel never becomes key/main, preserving the host's input focus. The controller asks `attributes(forCharacterIndex:lineHeightRectangle:)` for inline index zero. `CandidateAnchor` keeps the first usable rectangle for the composition. Later candidate updates, caret moves and paging reuse it without querying the host again. Composition start, commit, cancellation, client change and loss of presentation ownership reset the anchor. If it no longer belongs to a connected display, a fresh lookup can establish a new anchor. An unavailable first rectangle keeps the panel hidden until a subsequent refresh obtains valid geometry. SI retains its screen, origin and height checks for the first rectangle. `CandidatePlacement` uses the left edge at the rectangle's vertical midpoint to select the display, clamps the panel within its visible frame and flips the panel above when there is insufficient space below. The package's `SIPresentation` target compiles the same selection and AppKit view sources.

This policy adapts the fixed-position mode in the GPLv3 MSIME macOS source at revision `ab1918ff6eaeab26adbbf90a2388b88b46bc94bf`. MSIME exposes a cursor-following setting and enables it by default. SI uses the fixed behavior for its candidate window. See [the anchor policy](https://github.com/metasequoiaime/msime/blob/ab1918ff6eaeab26adbbf90a2388b88b46bc94bf/platforms/macos/src/input/InputController.mm#L4501-L4518) and [the screen selection rule](https://github.com/metasequoiaime/msime/blob/ab1918ff6eaeab26adbbf90a2388b88b46bc94bf/platforms/macos/src/candidate/CandidatePlacement.h#L54-L57).

`SI_DEBUG_CANDIDATE_GEOMETRY=1` in the input method's explicit launch environment enables `CandidateGeometry` debug logs. It records the IMK bundle identifier, presentation revision, the initial host rectangle or reused anchor, the requested panel frame and the frame AppKit reports after showing the panel. The records contain geometry and identifiers only.

`CandidateStyle` supplies dynamic warm-neutral light and dark palettes. The selected candidate uses a soft peach/umber background with an orange number and ordinary adaptive label text. The system Increased Contrast preference strengthens the card border and outlines the selection. The default 36-point-high strip lays out up to six 28-point candidate buttons horizontally and reserves a trailing expansion chevron with a subtle divider. Each button keeps a compact gap between its number and candidate labels and fits its full text and source symbol, without a fixed per-cell width cap. Extra retained window width does not stretch compact buttons; narrower screens proportionally shrink them without overlapping the chevron. Text-cell insets are included in width measurement; labels with too little room to draw a complete glyph hide rather than clipping through a symbol. Full text remains in accessibility and tooltips. Expanded mode displays one page of four six-candidate rows, up to 24 choices. `CandidateSelection.visibleRange` is the active six-choice numbered row; `displayedRange` is the current whole page. Page count/controls use 24 choices per expanded page and six per collapsed page. Retained Chinese characters can extend the list beyond the ordinary 27-choice budget. Each row repeats numbers 1–6; only the active row has full-strength numbers and a row highlight. Mouse buttons retain identities across every displayed row, and accessibility help identifies the page, row and column. Expanded natural width uses the widest visible candidate in each column, including number/source spacing, so lower rows can widen the window beyond the compact strip. All rows share those six column origins and widths, including on narrow screens. The shared columns reserve a minimum number/glyph budget before sharing extra width. Cell content and selection backgrounds fit the candidate within its column rather than stretching short words across a wide slot. Number/text insets follow the shared column width to retain vertical alignment. Tight cells reduce padding and hide source icons while retaining full tooltips/accessibility; preferred widths remain independent of constrained icon visibility. `CandidatePanel` measures against the anchor screen's available width before placement. The collapse chevron stays at the top right. A footer with page count/previous/next controls appears only for multiple pages. Ordinary word language descriptions are hidden visually; punctuation variants show small E/C badges immediately after the text in both layouts, and their literal fallback shows A (As Typed). Prefix/personal/literal/verbatim hints use the same small symbols in both layouts; full source descriptions remain in tooltips and accessibility labels. Exact consumed spelling stays in tooltips and accessibility descriptions. Language identity, full text, exact consumed-input descriptions and selection state remain available in accessibility labels and tooltips. Both layouts retain pending geometry, refresh rows on accepted provisional delivery, and disable selection, paging and expansion until full results arrive. Horizontal and vertical scrolling never change pages or selection. Clipping labels never changes committed text.

`scripts/generate-icons.swift` produces `InputSourceIconTemplate.tiff` on a 16-point canvas with 16×16 and 32×32 pixel representations. The rounded badge is opaque, while the SI glyphs are cut out with destination-out blending. `TISIconIsTemplate` is true, allowing macOS to tint this alpha mask for menu-bar appearance and selection without flattening opaque lettering and background into a solid block. There is no separate alternate color bitmap. The new resource name distinguishes it from the former full-color assets; installed sources retain their identifiers, connection, and language settings. Core Text glyph bounds, rather than the font's full line box, determine centering. Both representations carry the same logical size, avoiding a 32-point icon in system input-source rows. Resource previews and bundle checks do not establish actual menu-bar rendering; verify the installed update in the login session.

App Sandbox is disabled because the legacy InputMethodKit server uses interprocess connections with text clients. Accessibility and Screen Recording requests are confined to explicit Settings actions. SI does not request Input Monitoring or install a global event tap. `LSUIElement` keeps the input-method process out of the Dock. Closing Settings does not terminate the server.

`LanguageSettings` is main-actor-isolated and observable. It persists enabled-language booleans and the punctuation behavior in the stable `com.caterm.si` defaults domain. Both languages default to enabled. A separate punctuation-candidate boolean defaults to false, persists independently of the delimiter policy and increments the configuration generation when changed. InputSession copies this option into each immutable request engine; reconfiguration rejects obsolete results while retaining exact marked input. Absent or unknown punctuation preferences default to Keep Composing (`asTyped`); explicit saved smart/confirm policies remain selected. Settings take effect when the next key event refreshes a composition. Disabling all languages leaves literal input available. Shift and Caps Lock do not select a language mode.

The input menu rebuilds independent English/Chinese checkmarks from `LanguageSettings` whenever IMK requests it. Separate Objective-C selectors toggle the same persisted properties used by Settings, with no key equivalents or active-language mode. They use the existing main-thread IMK callback bridge and immediately reconfigure/update only the controller's active composition, preserving source spelling and caret while rejecting obsolete results. Other sessions observe the change at existing configuration boundaries. Direct-input application rules still take precedence and are not modified by language checkmarks. The selectors do not rely on a menu item's target or represented object surviving IMK's command-dictionary bridge.

The Settings window uses a sidebar and a scrollable detail pane. Search matches page names and common setting labels in the current interface language and English. The visible page binds to the existing settings models. Typing, personal data, optional permissions and software updates have separate pages, and their existing management sheets and confirmation actions remain attached to their controls.

The Xcode Run scheme passes `--settings`; normal system launches keep the process in the background. The installed app exposes Settings through the input menu and on reopening the app.

## Software updates

`AppDelegate` retains one observable, main-actor `AppUpdater` for the process lifetime and passes it to Settings. IMK dispatches the input-menu selector to `SIInputController`, which forwards it to that same instance. Both menu availability and the forwarding callback use the existing main-thread callback assumption; no client/composition state is shared with the updater and no additional unsafe isolation escape is used. This follows the installed SDK's `doCommandBySelector:commandDictionary:` contract rather than relying on an NSMenuItem target surviving the system menu bridge. Sparkle's KVO availability is delivered through a main-actor task, and the action rechecks the live updater before starting a check. Closing Settings does not tear down either the updater or `IMKServer`.

The app target alone links pinned Sparkle 2.10.0. Core/storage/package tests have no network or updater dependency. Only Release builds at `~/Library/Input Methods/SI.app` start Sparkle; Debug and uninstalled copies explain the disabled action in Settings. `SUEnableAutomaticChecks`, `SUAllowsAutomaticUpdates`, `SUAutomaticallyUpdate`, and `SUSendProfileInfo` are false. A user-initiated check uses the standard Sparkle UI, validates the EdDSA archive signature before extraction, and requires the user's install choice. Normal termination still flushes learning and phrases before replying. The app-bundle update replaces SI in its existing location and restarts it; native input-source recovery and host/focus behavior still require manual verification.

`SI_UPDATE_ARCH` defaults to `universal`; packaging explicitly sets it to the selected architecture and sets `SI_UPDATE_FEED_URL`. The resulting `SUFeedURL` points to SI's separate `si/channels/mac/stable-<arch>.xml`, so a Universal installation stays on the Universal channel on either CPU. No input text, phrase content, learning data or host-document content is supplied to Sparkle. Its update preferences remain separate from the existing language/learning domain. See [privacy](PRIVACY.md#software-update-requests).

## Distribution tooling

`scripts/package-dmg.sh` and `scripts/release.sh` share `scripts/release.py` and the existing SI Xcode target. Packaging builds Release for Universal or a selected architecture, signs a staged copy including Sparkle's nested helpers, and wraps it in a native Installer package inside the DMG. `scripts/installer/Distribution.xml` restricts installation to the current user's home domain and requests `RequireLogout`; macOS Installer owns the final Log Out button and normal save/cancel handling. Its preinstall script rejects a running SI or foreign bundle and lets native Installer replace existing SI without creating an app backup. Bundle relocation is disabled so other built/installed copies cannot redirect the payload. Native strict-ID matching is disabled only to permit the legacy `com.caterm.si` migration; preinstall explicitly permits only that ID and the current SI ID. Publication also notarizes/staples the app and produces an app-only update ZIP signed with Caterm's existing Sparkle Keychain identity; it never routes the home-only pkg through Sparkle's privileged package installer. Publication requires Application/Installer signing, notarization and a clean checkout, includes corresponding committed source, and verifies anonymous R2 downloads before conditionally promoting the independent SI JSON channel and then the Sparkle XML feed. The XML uses `CURRENT_PROJECT_VERSION` for comparison and `MARKETING_VERSION` for display. Cached archives have their EdDSA signature rechecked. Downgrades, same-version conflicts and competing conditional writes are rejected. All build/release files stay under `.build/` by default. Running packaging does not install, launch or log out; installation/logout requires the user to run the package and click through macOS Installer. See [RELEASING.md](RELEASING.md).

New publications increment the Xcode patch/build metadata after preflight and commit only that version file, keeping the built app and corresponding source archive tied to the same revision. An architecture-local pending marker under `.build/` preserves the chosen version for failure retries. Successful publication clears the marker; `--no-bump` explicitly reuses the current version for another architecture or a retry without local state. Dry-run/local packaging do not mutate versions or Git history.

DMGs use compressed UDZO with an explicit HFS+ filesystem. This avoids inheriting APFS from the staging volume and its reproduced source-folder image-sizing failure; see [DMG troubleshooting](RELEASING.md#dmg-creation-reports-no-space).

## Offline model experiments

`corpus/prepare_raw_text.py` extracts sources into versioned
`chinese/prepared/raw-text-v2` bundles. Six archives retain their existing pins;
local SI TXT, the manifest-pinned dialogue download, and optional Chinese
Chatbot Corpus files are independently snapshotted and verified. `readers.py`
owns the shared archive readers. `local_sources.py` owns SI and dialogue
parsing, and `chatbot_sources.py` reads the eight upstream chatbot layouts. OpenCC
t2s runs before output line accounting; original source bytes and origin IDs
remain unchanged. SI conversation boundaries and dialogue dataset/split/turn/
parent metadata survive in line-range sidecars. Existing output identity includes
input, code and normalization. Dialogue preparation skips LCCC-base because
the pinned LCCC source extracts it separately.

Application dictionary CSV sources and attribution are tracked. The Rust
resource tools prepare snapshots separately from the app build.

`eval/ranking/test.jsonl` contains the 220-query synthetic regression suite, replacing
all former root evaluation datasets and model adapters. It stores authored exact
source/target pairs, category/template families and bilingual configuration,
without candidate snapshots or a train/dev split. The reproducible standard-library
generator uses explicit newly authored text/readings and a fixed seed; it imports
no old evaluation or training data. Every semantic/template family is limited
to two representative cases; no global count is filled with slot substitutions.
Documented regressions, six requested English hard cases and 100 short Chinese
cases covering homophones, word segmentation and syllable boundaries are
recorded explicitly. Candidate generation belongs to the
engine under evaluation; missing targets remain in metric denominators. The
existing `SICandidateExport` protocol exports the first 32 eligible complete
nonliteral/noncompletion dictionary-only bilingual results. The helper scorer
reports exported-pool recall, Top-1/Top-5, MRR, categories and a family macro; it
measures the exported pool. Independent annotation and model-corpus overlap
audits remain open. [Dataset and commands](../eval/README.md)

`llm/reranker_small/` implements an independent 7,419,392-parameter causal character-LM baseline: four width-256 pre-norm blocks, four heads, 1,024-wide FFNs, tied embeddings and 256-token context. Its explicit preparation imports verified raw public sources through package-compatible corpus readers, retaining articles/paragraphs, punctuation and English word spaces. Source/group hashes keep Wikipedia pages and conversation turns together; normalized document deduplication and exclusion of cross-split long-paragraph copies reduce exact leakage. Training-only vocabulary, byte fallback and immutable token/window arrays preserve text without joining documents. FP32 training supports strict CPU/MPS resume with RNG/cursor state; CPU is tested bitwise and MPS weights within measured numerical tolerances. Token-loss evaluation, supplied-candidate scoring/benchmarking and inference-only export are separate commands. Bounded validation uses a fixed permutation across source windows. The local 30,000-step checkpoint supports explicit offline Core ML export; native comparison and app staging are removed pending redesign. Pinyin generation, hard-negative ranking fine-tuning and quantization remain separate work.

`llm/` groups model families into `reranker_small/`, `reranker_large/` and `pinyin_to_text/`. The converter and small offline LM framework are implemented; the large reranker remains planned. Existing converter modules, data/configs, prepared datasets, runs and reports are relocated together, with Python module bytes and checkpoint/data identities preserved. Shared dependencies and `.venv` remain at the workspace root. Compatibility imports plus the `scripts/` and `configs/` links resolve the same conversion implementation; explicit converter commands use `llm.pinyin_to_text.*`. The small reranker has no native runtime integration; representative ranking quality remains unverified. The large reranker has no native runtime.

The corpus acquisition also supports the latest complete official Chinese Wikipedia current-article dump. Explicit `wikipedia --latest` resolution checks completion metadata, pins a dated URL, verifies the official SHA-1 and records a local SHA-256. The full raw archive retains original simplified/traditional wikitext; streaming preparation selects namespace-0 nonredirect pages and retains page/revision URLs, with Wikipedia's CC BY-SA 4.0 terms kept separate. Existing prepared bundles validate against their own frozen source locks so adding/updating a source does not invalidate historical runs.

The Chinese corpus pipeline extracts full text from pinned public archives and
explicit local collections. It keeps the source locks, text/document ranges and
attribution together. The lexical reading exporter uses the maintained Chinese
CSVs. [Corpus preparation and reading export](../corpus/README.md)

`corpus/english.py` independently acquires and prepares the reviewed English dialogue collection: PersonaChat/ConvAI2, BST, Topical-Chat, Taskmaster 1/2/3, ABCD, SGD and selected English OASST1 messages. It reuses checksum/staged-directory utilities without applying the Han cleaner. Publisher source bytes and full terms are pinned; preparation retains exact selected utterances, original turn/source identity, collection method and existing split membership. Missing upstream assignments stay explicitly unsplit. Alternate ConvAI2 speaker views and non-dialogue metadata are excluded; OASST1 keeps parent edges rather than inventing linear adjacency between replies. Source-separated immutable JSONL bundles carry copied attribution, hashes and measured selection counts. The verifier recounts the whole bundle against its frozen lock. These are acquisition artifacts, not a mixed training dataset or a runtime ranking change; future training still needs deliberate source selection and a broader overlap audit. See [the English guide](../corpus/english/README.md).

`llm/` is a separate Python/PyTorch spelling-to-text framework. Its default is a randomly initialized 19,711,488-parameter encoder-decoder: four encoder/four decoder layers, width 384, eight heads, feed-forward width 1,536 and vocabulary capacity 8,192. The initial budget is 2,000 FP32 steps with batch 16/accumulation 1 and activation checkpointing off. It has no dependency from the Swift package/app and does not replace the production candidate engine. `llm/pinyin_to_text/csv_data/` imports static `input,target` CSVs from explicit train/validation/test directories; filenames label source groups and an optional language defaults to Chinese. It checks source declarations, rejects cross-split normalized input/target overlap, deduplicates within a split and freezes source bytes/hashes with model-ready JSONL. There is no seed-based content generation, Pinyin conversion, noise augmentation, source-manifest importer or automatic split path.

The default `llm/pinyin_to_text/data/pinyin-csv/` contains only explicit character and short-word sources. Its initial 2,021/73/69 train/validation/test pairs select earlier SI-authored vocabulary and add uniquely aligned character/reading pairs from training words only, excluding held-out input/output identities. This materialization is static and audited; runtime preparation never decomposes words. Sentence, English/mixed and typo data remain in the separately retained 50,000-pair collection with the 0.403B config. Neither that data nor existing weights are migrated implicitly. Limits are 48 source and 16 target tokens; generation remains unconstrained, with no copy branch. The corpus has limited character coverage, including held-out symbols absent from training outputs, so raw fallback and a lossless tokenizer do not establish learned conversion for those symbols.

The tokenizer fits training rows only and preserves unknown Unicode through UTF-8 byte fallback. Training reads train/validation only; explicit held-out candidate evaluation can additionally use a frozen external CSV benchmark's selected split. Checkpoints retain optimizer/RNG/batch position, and inference export omits training state. Prepared artifacts are ignored by Git; maintained CSVs are source files. Setup, prepare, train/resume, validation/test, inference/export and smoke scripts use the same isolated environment. Each ordinary stage script has defaults from `llm/scripts/defaults.sh` and invokes only its own task; `data.sh` aliases preparation and `run.sh` aliases training. They share explicit versioned data/run/report paths. Setup and separate candidate evaluation/export require their own invocations; training retains its periodic validation loss and checkpoints.

Old datasets, generator code, configs and smoke artifacts were removed. Previously trained weights/run records remain usable for inference/export, but their deleted prepared data and compatible runtime are not available for resume. New CSV training uses a new experiment with strict dataset/config/code identity checks.

The model's MPS path materializes full encoder/cross-attention masks to avoid a reproduced PyTorch 2.6 shape assertion, preserving padding and causal constraints. Numerical CPU/MPS comparisons and varied-length validation cover that repair. MPS activation checkpointing also explicitly replays per-layer accelerator RNG state: the pinned PyTorch version otherwise skips MPS RNG capture, producing different dropout masks and incorrect gradients during recomputation. The reusable recomputation context restores the caller's RNG on normal/early-stop exit; nonzero-dropout tests compare all gradients, RNG advancement and repeated backward against ordinary execution. CPU/CUDA retain their existing mask and checkpoint paths, and resume releases the loaded CPU checkpoint payload after state transfer. The fix changes code identity, so pre-fix runs remain inference artifacts and cannot silently resume across it. These checks do not establish representative conversion quality or host compatibility. Native candidate identity, enabled-language coexistence, spelling alignment, prefix commits and cancellation remain SI's core/controller contracts. See [the training guide](../llm/README.md).

## Extending language support

1. Add a stable language identifier and display name to `InputLanguage`.
2. Extend the Rust engine's language and lookup handling with deterministic
   normalization, source spans and licensed data.
3. Update the C ABI and Swift bridge mapping, language preferences and Settings.
4. Test ambiguous sequences, disabled-language filtering, deterministic ranking, literal fallback, and composition resets.
5. Document dictionary provenance, performance characteristics, and limitations.

See the [conversion pipeline](#rust-conversion) and [ranking contract](UNIFIED_RANKING.md)
for the current Chinese and English paths.

## References

- [Apple: IMKServer](https://developer.apple.com/documentation/inputmethodkit/imkserver)
- [Apple: IMKServerInput](https://developer.apple.com/documentation/inputmethodkit/imkserverinput)
- [Apple: IMKCandidates](https://developer.apple.com/documentation/inputmethodkit/imkcandidates)

The installed SDK headers are the source of truth for imported Swift method names and callback signatures.
