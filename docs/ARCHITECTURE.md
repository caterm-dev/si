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
  → immutable CandidateRequest → synchronous full conversion
  → Rust decoder → ranked lexical candidates and source evidence
  → consented preference lookup → Rust final merge and presentation policy
  → revision-checked CandidateResult → AppKit candidate window or commit
```

Xcode copies `Data/Engine/main.silex` and `Data/Engine/words.sigram`
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

Each immutable engine owns bounded, in-memory lookup and gram-context caches.
Exact lookup, suffix reachability and correction traversal share dictionary
transition ranges keyed by the parent row range, depth and next byte. Tiny
ranges are searched directly; larger ranges use up to 8,192 direct-mapped
entries per language. Full key equality guards cache collisions. Separators,
source spans, completion eligibility and correction budgets are still checked
for the current input. No completed candidates or client composition buffers
are retained in these caches.

Scoring leases the existing prepared gram-context maps across requests,
including their continuation totals, with at most 8,192 entries per corpus.
The keys are lexicon word IDs; the cached values refer only to the immutable
gram snapshot. Numeric identity hashing avoids repeated general-purpose
hashing in the scoring loop; every map hit still checks the complete ID key.
Candidate/output equality and ordering are unchanged. Concurrent conversions use local computation if a cache is
busy and never wait for another conversion. A new base/user engine starts
with empty caches, so resource reloads and deletion cannot reuse old user
evidence. Preferences, preceding-text adjustments and candidate selection
are evaluated for the current request. Nothing is persisted or logged.
The lattice and its search paths are still rebuilt per request; incremental
beam-prefix decoding is not implemented.

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

Each dictionary edge adds a unigram or smoothed gram log probability in bits
and pays any spelling cost. A unigram uses its raw count divided by the sum
of all counts in its lexicon. Base and user lexicons use their own totals,
each shared across languages. Zero probabilities receive a finite floor
when converted to log scores so known zero-count words remain selectable.
Each gram uses its count divided by the total for the same history, including
continuations in every language. Base interpolation assigns at most 80% to
each observed gram distribution. User unigrams and user grams can raise the
current probability through bounded weights. Both histories retain word IDs
across language changes and stop at unknown tokens or other context boundaries.
Terminal completion pruning uses the largest possible unigram or continuation
probability across the active histories of both lexicons. It skips a path
only when the optimistic score falls below the destination beam's floor.
Scores use only the source consumed by each path. Whole results sort ahead
of prefixes, longer prefixes precede shorter ones, and score and stable
identity determine ties within a span. The engine retains distinct
languages for identical output and keeps the exact literal last.
The macOS app and the Rust CLI share this lexical scoring.

The Rust API exposes an opt-in Pinyin typo search through
`CandidateEngine::with_pinyin_correction`. It explores one missing key,
neighboring-key substitution or adjacent swap within a dictionary syllable.
Every typed letter is retained in the spelling alignment. Existing completion
handles unfinished spellings. The search visits only branches present in
the sorted dictionary prefix ranges under per-position and per-composition
probe budgets and a 48-letter dictionary match window, reserving work for
edits late in the input. It keeps a
separate four-path correction beam per position in both search modes.
A backward reachability pass skips edits
whose remaining input cannot be decoded with exact dictionary words and at most
one bounded final-word completion. The edited word itself must still finish
matching its dictionary reading. A correction earlier in a sentence therefore
stays available when a newly typed suffix is not yet a complete syllable.
The first opt-in prepares a bounded shortlist for unusually dense
spellings using the same unigram prior as the decoder, including a paired user
lexicon when available. Toggling correction on the same engine reuses this
index. If none of its entries can accommodate the edit
and separators, a bounded set of alternate syllable-boundary patterns is
checked. Equivalent spellings such as `lü` and `lv` share a pattern.
Ordinary lookup order is preserved. Equivalent edits
leading to the same dictionary entry and source endpoint are scored once
with their lowest valid edit cost. A missing key or adjacent swap costs
eight bits. A neighboring-key substitution costs eleven bits.

In statistical correction, a complete exact path supplies a pruning threshold as soon as the search
reaches the end of the input. Subsequent lexical steps add nonpositive scores,
so corrected paths that cannot clear the threshold can be discarded. The same
upper bound skips scoring a transition that cannot enter its destination
correction beam. Paths traversing the same lexical edge reuse its unigram
prior. Their word-gram evidence is scored against each
path's own history. Corrected paths receive no spelling preference bonuses. They preserve original UTF-8
consumption spans and explicit apostrophes. Explicit multi-byte umlaut aliases
stay intact during key edits. Each result set contains at most four whole
Chinese suggestions, each bounded to 4,096 output bytes.

An exact enabled English dictionary match, an exact personal phrase code,
uppercase letters or non-Pinyin units skip correction search. Inputs under
four normalized letters also skip correction.
For duplicate output at the same span and language, the regular derivation
supplies the candidate. Distinct whole results share the same score order.
A suggestion must lead the strongest complete exact-spelling
Chinese or English path after paying its edit cost. Conservative mode
requires a lead of more than two bits. Higher-recall mode requires any
positive lead. Both modes use preceding-text evidence to score corrections
and use the stronger exact path score with or without that evidence as their
threshold.
Higher-recall mode also lets a corrected path fall back to its score without
preceding-text evidence minus a two-bit cost when that is stronger. The same score
governs correction pruning and ranking.
Abbreviations and completions are excluded from the exact-path threshold.
A corrected terminal completion additionally clears a separate threshold from
ordinary whole-input completions, including ordinary abbreviated-prefix paths.
It pays the existing completion spelling cost and the single-edit cost and uses
the same confidence margin and stronger with/without-field baseline. Exact
corrected outputs keep their existing admission rule. Completion upper bounds
include corrected histories; ordinary-prefix masks do not prune the separate
four-path correction beam. The
`Candidate::correction` metadata identifies suggestions that require explicit
acceptance by the caller. Callers can use `Candidate::default_for_whole_input`
to choose an ordinary whole candidate or fall back to the original text.
The metadata gives the edit kind and the edited dictionary
word's span in the original UTF-8 input. Such candidates carry no
automatic-confirmation evidence. The native bridge exposes this metadata
through a separate accessor and accepts an explicit correction mode on a live
engine under exclusive access. Configure it away from the event handler.

The Swift adapter carries the correction marker and excludes suggestions
from learning and automatic confirmation. The candidate window initially
highlights the first displayed result for every list. Space confirms a
highlighted correction through the same explicit selection path as a digit
or click. Suggestions compete for the first four ranked choices alongside
ordinary candidates and completions. The shortlist preserves their rank.
The compact window uses a pencil icon and the expanded window displays the
spelling-correction label. The accessibility label
includes this information. Punctuation variants use ordinary candidates only.
The Typing Settings switch defaults on and honors saved choices, including both
legacy enabled modes. Each request captures whether correction is enabled. The
bridge prepares the lookup index when the base or user engine opens, and queries
can enable correction without mutating the shared engine. Secure input disables
suggestions.

The independent Local model ranking switch defaults on and lets full conversion
add a bounded whole-input reward from the packaged small FP32 character model
after the statistical search. It scores up to 12 eligible whole-input candidates
in statistical order without a score-gap cutoff. The native bridge shares the immutable model
with user snapshots and returns the reward separately from lexical and
contextual scores. Secure input disables inference, and the engine falls back
to statistical ordering if the model cannot score the pool.
[Ranking policy](ranking-architecture.md#local-model-ranking)

The app passes opted-in token and consumed-spelling preferences to the search.
Their larger value counts toward the shared 32-point frequency cap.

At composition start and after a prefix commit, `SIInputController` asks the
active InputMethodKit client for the full UTF-16 range before the insertion point.
It revalidates the client and ranges across the read. The Swift request carries
that text separately from composition spelling.
It uses an empty context in secure input or when the host cannot supply the full
range. Direct input bypasses conversion. The snapshot is transient and local.

Rust selects the last sentence or unfinished sentence fragment from the supplied
text, including the last completed sentence after terminal punctuation. The base
gram history uses base-lexicon segmentation. When user grams are available, the
user gram history uses the user vocabulary as an overlay on the base lexicon.
Each history keeps the final consecutive recognized words up to its gram
order. The difference between the first word's conditioned and
unconditioned log probabilities adjusts ranking before pruning. Later words
use the history from the composition. Candidates containing personal or verbatim segments receive no field
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

Builds require a new destination. `lexicon add` sums each incoming identity
across the supplied sources and sets the matching word's count to that
total. New words are appended and entries absent from those sources stay
in the dictionary. Corpus add continues to accumulate gram counts. Keep
source CSVs and tokenized corpora separately for reproducibility. A sidecar lock serializes import
writes to each destination, and the binary snapshot is replaced only
after the entire import succeeds. Each dictionary has its own file, such
as `main.silex` or `user.silex`. Pair a gram snapshot with the lexicon that
assigned its word IDs. Incremental imports preserve existing IDs, so gram
snapshots remain compatible when words are appended. To remove entries,
build a fresh lexicon and regenerate its word grams. The new build assigns
its own word IDs.

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
nonempty line. The shared Rust segmenter indexes exact output spellings and
uses a DAG with one best predecessor per source byte boundary to maximize
the sum of smoothed unigram log probabilities over a complete path, minus one
bit per segment. An extra segment must improve the unigram score by more than
one bit to win on score. Whitespace and punctuation boundary edges have zero
cost. Word counts are summed across readings of the same exact written form,
with one added pseudo-count per form and a half-count unknown-scalar fallback. When
a user lexicon is present, its counts add at most 32 pseudo-counts per form;
paired base/user entries remain one lexeme. Scores are precomputed when the
immutable index is built. Equal path scores prefer the longer final edge,
independently of word-ID allocation. Matching edges are visited without
materializing every path, and per-call state grows linearly with source bytes.
This written-text segmenter uses unigram scores and supplies tokens to the
separate word-gram scoring stage.

This allows `没有 / 输入法` to beat `没有输 / 入 / 法` while preserving exact
UTF-8 byte ranges. The same algorithm serves user ingestion and preceding-field
context. ASCII-starting runs retain their longest known spelling or whole-run
fallback, including existing letter/number classification. Matches end
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
An ambiguous Han match passes only the matched word to `pinyin_pro`. The
Pinyin reader verifies that the returned syllables align with the word's
characters and removes tone marks. The segmenter compares the full reading
with the lexicon, including SI's umlaut aliases.
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
`lexicon add` imports completed rows from this format and uses their
aggregate `count` as the reading's absolute weight. It skips blank readings and leaves previously
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
`--language zh-Hans` or `--language en` filters by primary lookup index.
The filtered export retains source word IDs and every alias of the
selected words.

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
lexicon. One immutable frequency-scored segmentation index combines the base lexicon and
the user's current entries. Identical text, lookup index and primary reading
resolve to one lexeme. The same token-based Pinyin lookup disambiguates known
Han readings.
The profile allocates its own word IDs and increments only its own counts,
including for matches found in the base. New English runs preserve case and
use lowercase lookup keys in index 1. Before ordinary ASCII segmentation, user
ingestion recognizes common unquoted ASCII mailboxes and uses the full address
as one token, including digits, dots and plus tags in the local part.
For HTTP(S) addresses and bare ASCII domains or IPv4 addresses, it consumes
the entire address and uses only the host and any explicit HTTP(S) scheme as
the learned word, with a lowercase ASCII lookup key. User info, ports, paths,
queries and fragments contribute no vocabulary or gram tokens. It uses
surrounding text to delimit addresses in prose. Isolated ASCII letters are
skipped even when present in either lexicon. They end the
word-gram sequence without adding or incrementing user vocabulary. Existing
entries and counts remain intact. Base paragraph imports retain their English
review and letter-placeholder handling. A Han character outside both lexicons
uses a derived reading when available. Spaces preserve word adjacency.
Punctuation, numbers and unresolved text end a word-gram sequence, as does
each sentence boundary.

User learning applies its occurrence, directional-share and lift thresholds
to bigrams in `user.sigram` whose two tokens have full Han Pinyin readings
in `user.silex`. It joins their text, skips existing Chinese words and
derives a full Pinyin reading for the new compound. The compound starts
with the observed word-pair count and participates in later segmentation.
Earlier word grams retain the segmentation used when imported. A newly
discovered compound competes by score rather than automatically winning by
length. All sentences in one ingestion batch use its starting snapshot;
counts are applied only after segmentation completes. Existing statistics
are not retokenized automatically. Rebuilding base statistics requires the
original corpus; retained user samples are not a complete training history.
Base and user snapshots can be loaded together as independent
`EngineResources`, each with its own lexicon-to-gram ID mapping.

The profile serializes updates with a stable lock. It writes the paired
lexicon and gram snapshots and batch receipts into an inactive generation.
One atomic pointer change publishes the generation. Readers load the selected
pair under the same lock. A repeat batch ID prevents recounting. Opening a
valid word pair removes obsolete character and recent-sample files without
reading them. Clear publishes an empty profile and deletes both generations.
The profile retains derived words, counts and opaque batch IDs. Git ignores
the `.si-user` directory.

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

`InputSession` owns the buffer, character-aware caret and candidates for each
client. The app uses synchronous generation. Every edit runs full conversion
before returning to the controller. The marked
spelling and candidate window then update from the same completed result.
The window immediately selects its first candidate and enables its controls.
Space, digits, mouse actions and navigation use that displayed list. Prefixes
consume validated source boundaries and keep the exact remainder editable.
The core retains deferred request and narrow-preview APIs for offline fixtures.
The app uses the synchronous path for edits and reconfiguration.

Swift combines Rust's lexical scores with eligible preferences and
preceding-field context. The input window uses that statistical order in
both correction modes. The shared core also supports coverage-adjusted
ordering for library callers. Complete candidates precede prefixes,
and candidates within each prefix span compete by score.

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
scroll position. Compact rendering shows one numbered row. Down expands the
same ranking into a vertically scrolling grid. Space, numbers and mouse clicks confirm the same candidate IDs, and
the displayed global first choice stays neutral for Personal Learning. Pending
engine searches disable stale rows until revision-checked results arrive.

## Automatic prefix confirmation

`LanguageSettings` persists a separate, initially disabled automatic-confirmation option. Its in-process configuration generation also changes when languages or punctuation/confirmation settings change, invalidating evidence even if a setting is toggled away and back between input events. Secure event input disables the option at the controller boundary independently of learning consent.

When enabled, full `CandidateRequest` generation captures transient `ConfirmationBoundary` evidence from the existing lattice: exact source-character counts (including ü/u: normalization and trailing separators) and cumulative output UTF-8 byte counts at up to eight leading, exact Chinese lexical nodes. Immutable shared trace tails bound per-path evidence without copying boundary arrays on each expansion. Capture stops at abbreviation, completion, personal, verbatim or English edges; full results retain earlier exact boundaries. Capture is disabled for provisional searches and ordinary engine callers. Evidence does not affect identity, scores, pruning, lexical presentation or output bytes.

During synchronous generation, `AutomaticConfirmation.prefixes` compares the leading whole Chinese candidate with every whole alternative within three ranking-score points, including eligible other-language competitors. This is a relative-score band, not a calibrated confidence probability. A proposed prefix must have identical committed bytes and source/output boundaries on every competitor; no textual-prefix or syllable-count guess substitutes for alignment. Mixed/personal/verbatim leaders, uppercase spellings, malformed output boundaries and non-Pinyin symbols do not produce proposals. An exact English word of at least four letters starting at a leading Chinese lexical boundary also suppresses proposals, independently of enabled languages; this protects tails such as `title` from being treated as Chinese-only spelling. Explicit syllable separators constrain this check. Literal fallback remains present but is not statistical evidence against every conversion.

`InputSession` retains at most eight client-local prefix observations. Only accepted full results advance stability, once per distinct appended spelling; pending, provisional, stale and cross-session results cannot confirm. Continuous confirmation requires two observations, six additional source characters since the first observation, at least four remaining output characters and eight remaining normalized letters. Pause confirmation requires at least 1.8 seconds since input, 0.6 seconds since the observation, a prefix of at least two output characters, two remaining output characters and four remaining normalized letters. Both use the same consensus proposals and complete lexical boundaries. Editing/navigation suspends evidence; only fresh end-of-buffer typing can restart it. Configuration, reset, commits and host boundaries invalidate evidence and the timer revision. A prefix commit resets observations, so a timer cannot repeatedly drain a stationary composition.

`SIInputController` attempts continuous confirmation on accepted result delivery. Its single cancellable, weakly captured main-actor pause task rechecks session revision, current client, settings and secure input before the same `automaticallyConfirm` method. Neither path synchronously resolves a search. `.automaticConfirmation` has zero learning weight. The ordinary prefix commit/marked-remainder path handles insertion exactly once without an English space and refreshes the local field context after insertion. Already committed text uses ordinary host editing; there is no cross-host automatic reconversion/undo contract. Native focus/timer delivery remains an integration check.

## Personalization and storage

`ApplicationMemorySettings` is the global entry point for learning settings. The retired global `PersonalizationSettings`, its Settings views and `LearningStore` are removed from the app and package. Launch/termination prepare or flush app memory, explicit phrases and the independent Input History store; input uses a shared global profile when learning is enabled and input is not secure. Disabled or secure clients use base ranking. No disk I/O or dictionary initialization runs in the keystroke handler.

The UI-independent `LearningProfile` and `LearnedPreference` models remain shared ranking primitives for Personal Learning. Single-language frequency records can influence whole/prefix and eligible internal tokens before bounded limits, preserving base/personalized search beams and the shared 32-point cap. Chinese single-character outputs do not transfer into other compositions. Core contextual-ranking/session APIs remain available to library fixtures, but the application does not enable, store or expose previous-word pair learning. Old global archive schema versions are no longer loaded or migrated.

`PrivateArchiveFile` shares regular-file validation, bounded reads, owner-only permissions, atomic replacement and erase mechanics across the remaining storage actors. App memory provides an actor-isolated existence/deletion operation for the retired `preferences-v1.json` path without decoding its contents. Settings exposes explicit deletion with independent progress/error feedback. Old consent flags are ignored and removed only with that deletion. Existing files are not erased or assigned to guessed app scopes; the inactive old archive receives no automatic retention maintenance.

Personal Phrases now displays `SentenceLearningSettings.entries`, copied from the same immutable Rust user snapshot as the decoder. `SentenceLearningStore` serializes explicit entry edits with ingestion. The C ABI uses borrowed UTF-8 views for reads and owned exact old/new rows for edits. Rust validates the original row under the profile lock, rebuilds the paired lexicon/grams, remaps surviving IDs and aliases, and atomically publishes. Frequency-only edits retain grams; changed/deleted identities lose their grams. The UI removes old pins and JSON import/export; the app no longer opens `phrases-v1.json` or passes its phrases into conversion. Core phrase fixtures remain supported. User-model ranking applies in eligible conversion sessions, including with Personal Learning disabled.

### Personal Learning

`ApplicationMemory` contains global `ApplicationVocabularyEntry` records keyed by normalized consumed spelling, language/mixed identity and output, without application identifiers. Each record retains a noncontextual `LearnedPreference`, aggregate use/correction counts, base score, lexical-unit evidence and optional latest deliberate-selection time. Every eligible confirmation increments usage; only explicit nonfirst choices update the remembered choice and correction count. Every third correction still adds one frequency point, up to 32, stored as `exp2(bonus / 12) - 1`. `LearningProfile(retainsIndefinitely: true)` disables age expiry and strength decay for this product profile; the default library policy remains available for historical fixtures. Zero-strength usage-only rows inject no candidates; one correction can inject its saved candidate immediately. Literal, personal/verbatim, punctuation and automatic/delimiter commits never train. No sentence-token decomposition is saved.

`InputSession` owns a bounded `CompositionLearning` accumulator for successful manual prefix confirmations while Personal Learning is eligible. The controller acknowledges each fragment only after insertion and client, consent-generation and secure/direct-input revalidation. Exact consumed source and submitted candidate bytes are joined only when the unchanged remainder is fully confirmed; base scores and lexical counts are summed without scoring hypothetical suffixes. The completed aggregate is additional vocabulary evidence, never a second host insertion or Input History event. Individual fragment learning remains unchanged. Any nonfirst selection supplies whole-spelling correction evidence; all-first sequences stay neutral. Edits, reset/focus/context or relevant configuration changes, disabled/secure learning, failed insertion, source mismatch, size overflow and literal/personal/verbatim/punctuation/automatic/delimiter/AI fragments discard the aggregate. The temporary state stays per client, has no disk/network path, and uses existing schema-4 records and deletion/capacity rules after completion.

A bounded spelling-to-record index maintains one latest deliberate choice per normalized spelling. A new correction clears the former choice's selection marker, even when wall-clock timestamps tie, without deleting its aggregate counts or frequency strength. `ApplicationMemorySnapshot.preferredCandidateID` resolves the whole normalized input against enabled languages. The shared engine places this ordinary whole candidate after explicit personal pins and before score-ranked alternatives, leaving all other candidates in their deterministic score order. Prefixes, shorter spellings and longer inputs never gain forced placement. A prefix confirmation can supply the remembered choice only when its consumed spelling is subsequently typed alone. Exact literal input remains explicit and language-aware identity is unchanged. Forgetting a selected entry restores ordinary ranking, without reviving an older selection marker.

`ApplicationMemorySettings` owns default-off global learning consent and one cached immutable snapshot. Learning settings/snapshot/record APIs have no app parameter or exclusion list. The retired `applicationMemory.vocabularyExclusions` key is removed without changing existing learning consent. The controller still reads the actual IMK client's bundle identifier for the independent direct-input rule and focus/reentrancy checks; learned records do not retain it. Disabled, direct-input and secure clients neither record nor use the global profile. Client/settings revisions continue to reject stale candidates, clicks and automatic-confirmation tasks. `CandidateSelection.confirmationReason` compares against the displayed first candidate after shortlisting; Space, number, mouse and navigation back to the first candidate stay neutral. First cells on later pages remain nonfirst. Punctuation's safeguards remain separate.

`ApplicationMemoryStore` performs actor-isolated I/O at the existing `SI/Personalization/application-memory-v1.json` path, with vocabulary-only schema 4, a 64 MiB file limit, owner-only permissions, atomic replacement and revision-ordered saves/deletion. Schemas 1–3 migrate atomically, stripping app identifiers/history and merging equal record identities: counts are summed with existing one-million caps, latest usage/base metadata is retained, and strength uses the maximum rather than stacking app bonuses. Schema-1/2 mixed default/correction evidence resets to neutral; schema-3 strength/corrections survive. No old schema supplies an exact-choice marker because it lacks a deliberate-selection timestamp. Age alone no longer invalidates retained records. Malformed/unsupported archives remain untouched; migration write failures propagate and pause loading. The retired `preferences-v1.json` archive is never decoded or imported and keeps its explicit deletion control.

Vocabulary retains at most 5,000 records; capacity eviction removes least recently used entries with identity tie-breaking. There is no timed expiry, decay or daily expiry task. Saves coalesce for 300 ms and flush on normal termination. Settings provide global search, Forget and global clear/archive erase under **Personal Learning**, with no application picker, pause or app discovery. Existing learning consent persists; old history flags never grant learning consent. The former App History draft/completion feature and previous-word pair learning remain absent. The separate Input History below does not provide candidates. Candidate-choice learning uses confirmed SI text. Sentence Learning uses Return field snapshots and a separate Rust archive.

### Input History

`InputHistoryEntry` is a core value for one submitted composition: UUID event identity, timestamp, exact consumed source/output, optional language, mixed identity and commit reason. `SIInputController.apply` captures independent history consent/secure state and generation before calling the host's `insertText`, then rechecks the returned insertion/reentrancy boundary, client/direct-input policy and history consent before enqueueing the record. Candidate, literal, personal/verbatim, punctuation and automatic-confirmation submissions are eligible; empty commits, cancellation, marked edits and passthrough keys outside composition never create a row. Prefixes use `InputCommit.input`, excluding its remainder; actual SI-inserted suffixes are included in output. This captures SI's insertion contract, not a readback/acknowledgement of the host document. No host text is queried.

`InputHistorySettings` owns independent default-off `inputHistory.enabled`, a serialized task chain, bounded displayed pages, consent/storage/read generations and in-memory failed-write retry entries. Personal Learning and all retired consent keys cannot enable it. The key handler only creates a value and queues work. Save errors pause new recording and retain accepted failed entries for explicit retry; turning history off keeps previously accepted writes/data. Clear advances the storage/consent/read generations, stops recording until completion, discards pending retry records and serializes database removal after in-flight writes. Older queued inserts skip obsolete epochs. Entry deletion follows prior writes and removes that event from pending retries, so retry cannot resurrect it. Read generations reject late search/page results. Normal app launch prepares the history actor alongside other stores; termination awaits its queued work.

`InputHistoryStore` uses the system SQLite library. Schema 1 lives separately at `SI/InputHistory/history-v1.sqlite3`, under 0700 directory/0600 file permissions with DELETE journaling. Each operation opens/closes its actor-confined connection; prepared SQL binds text with explicit UTF-8 lengths (including embedded NUL), and retrieval uses byte counts rather than C-string termination. UUID uniqueness makes retries idempotent while preserving repeated real submissions as distinct events. Append batches use transactions. There is no age/count eviction, full-archive rewrite or full in-memory load: newest-first pagination uses monotonic SQLite sequence cursors, returns at most 100 entries plus lookahead, and remains stable when newer events arrive or the wall clock moves backward. Search binds literal source/output substrings with ASCII case folding; no query/input text appears in error logs. Explicit row deletion uses secure_delete; explicit clear removes the database and journal/WAL/SHM sidecars, including corrupt/unsupported archives. This is not a guarantee of forensic erasure or backup deletion. Corrupt/unsupported opens preserve existing bytes. History is unencrypted and independent of learning/phrases/retired files, with no migration, ranking, completions, automatic training or network path. User-controlled export and offline preparation follow the separate workflow below.

### Sentence learning

Sentence Learning uses one before/after comparison per passed-through Return or Command–Return. After checking for marked text, the controller proposes a fixed range of 2,048 UTF-16 units starting at offset zero. It accepts a valid clamped response from the active `IMKTextInput` client or uses the attributed substring API if the actual-range API is unavailable. If the request fails, SI can use the former Sentence History read from field start to the caret within the same limit. SI holds the snapshot in memory, then reads the same client after 500 ms or before processing the next key. Activation and deactivation resolve a pending snapshot without reading from a different client. If the second snapshot contains the first as a literal substring, learning is skipped. An empty, replaced, unavailable or no-longer-focused field uses the earlier snapshot. InputMethodKit does not report completion of the host action, so the readback timing is a heuristic. Secure/direct input and storage or configuration changes can invalidate a pending comparison.

Return consumed during SI composition submits exact remaining spelling to the field. Individual candidate confirmations feed the independently enabled Personal Learning path. Sentence Learning observes the completed field at its Return boundary.

`SentenceLearningSettings` keeps up to 32 queued submissions and one in-flight or retry batch. The actor sends up to 128 KiB of UTF-8 submissions with byte offsets to the Rust bridge, which calls the same user ingestion and compound discovery used by the CLI. A batch ID prevents duplicate counts after a retry. Swift loads the published lexicon and grams into an immutable decoder. Personal Phrases exposes the entries, storage errors, retry and Delete All. Clearing invalidates pending work and waits for any in-flight writer before deleting both snapshots. Only the derived model and batch IDs persist. The legacy raw SQLite archive remains accessible for explicit deletion only.

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

`SIInputController` adapts key events to the core and maintains marked text in the client. It owns one `CandidateSelection` and one nonactivating AppKit `CandidatePanel` per client. Number labels, highlighted rows, keyboard navigation, Space confirmation, and mouse clicks use the same selection state. A composition starts collapsed with six choices per horizontal page. Expanding shows up to five rows of the same list. Switching layout preserves the selected candidate and digit. Ending the composition resets expansion and scroll position. Row labels remain presentation data; only validated candidate text is committed. Objective-C callbacks lack Swift actor annotations. The UI callback boundary uses `MainActor.assumeIsolated` explicitly; this relies on InputMethodKit delivering those callbacks on the main thread. Non-Sendable Objective-C callback arguments are captured using narrowly scoped `nonisolated(unsafe)` locals, and the controller explicitly declares `@unchecked Sendable` while its mutable state stays main-actor isolated. This boundary must be exercised during manual integration checks.

`CandidateBoundaryReader` reads at most four UTF-16 units before the current marked range on Space/number/mouse acceptance, validating the marked spelling, caret, client, presentation/key revisions, configuration and secure/direct-input state before committing. `CandidateSpacing` adds one leading ASCII space only when the actual submitted text changes between Han and English letters at that preceding boundary, in either direction. This applies to mixed, prefix and explicitly confirmed literal choices; punctuation candidates remain undecorated. Same-script boundaries, existing whitespace, digits, symbols and field starts receive no space. Confirmation never adds a trailing space. Unsupported boundary reads submit without guessing a separator; secure input skips reads and direct input bypasses confirmation. The decoration is inserted once with the candidate and included in independently consented Input History, while learning receives only the original candidate bytes. Boundary text stays transient and is never logged, stored or sent.

`MarkedTextState` suppresses repeated host updates when the exact composition bytes and UTF-16 selection have not changed. Full candidate deliveries update the panel without restarting identical host marked text. Edits, caret movement and cancellation still send the required update; commit, deactivation and client changes clear the cache. Identical visible candidate identities retain their row views; unchanged row configurations avoid label/accessibility writes. Changed identities still replace rows so removed controls cannot confirm replacement text. Panel resizing finishes layout before display. These remove redundant refresh paths; automated state/view checks do not prove that a reported transient system window is eliminated.

Inline spelling is sent as an `NSAttributedString` using `IMKInputController.mark(forStyle:at:)` with `kTSMHiliteConvertedText` over the full displayed UTF-16 range. This requests the system's thin, unselected underline instead of relying on a host's default attributes for a plain string. The style name does not confirm or convert the spelling: the existing `setMarkedText` selection, source buffer, display-only segmentation and `insertText` confirmation boundary remain unchanged. SI does not override the host's font, text color or background. Host autocomplete and exact native appearance still require integration checks.

Candidate panels additionally share one weak main-actor visibility owner. Activation or a current key event claims that owner and hides the previous panel; result delivery, timers, mouse callbacks and panel rendering cannot reclaim it. A late old-client deactivation cannot release a new client's owner. This shares only presentation ownership, never composition buffers or selection. The `activateServer:` override uses the existing main-thread IMK callback assumption, checked against the SDK declaration; actual callback ordering remains a native integration check. Per-controller presentation revisions reject work superseded by synchronous reentry during host marked-text, insertion and geometry calls.

After updating marked text and rendering candidate rows, `SIInputController` queues placement with `DispatchQueue.main.async`. It revalidates the client, ownership and presentation revisions at delivery and after host calls. SI probes inline offset zero, as defined by InputMethodKit, and uses the document-relative marked start as a compatibility probe. The first usable line rectangle intersecting a connected display supplies the anchor. `MarkedTextState` retains that rectangle across typing, deletion and caret movement. Commit, including prefix commit, cancellation, and client or focus changes clear the retained start. If the start is unavailable, a weak client-keyed cache supplies the last usable host rectangle, with the mouse location as the next fallback. Later placement can retry the start query until it receives usable geometry. The panel measures the latest rows against the selected display, tries below the anchor, flips above if needed and clamps to its visible frame. The same placement path runs when scrolling, expansion or prediction content changes the panel size.

`CandidateSelection` passes the complete ranked list through the thin Swift `CandidateShortlist` adapter to `si_engine::presentation::shortlist` without inspecting system font coverage. Candidate availability and shortlist allocation do not depend on installed fonts. Numbers, Space, keyboard navigation and mouse selection use that same shortlist. Labels use the system font and normal platform fallback; rendering does not filter candidate identities or change their exact committed bytes.

The public `si_engine::presentation` module owns final merging, canonical identity
comparison, exact/prefix ordering, pins and remembered-choice precedence, model
reward combination, coverage rewards, model-independent leader comparison for
automatic confirmation and shortlist
budgets. Its borrowed `PresentationCandidate` metadata is independent of conversion
resources and platform UI. Calls return input indices and retained lexical evidence;
output text and confirmation/source boundaries remain in the original candidate.
No font queries, disk reads or session state are involved. The CLI's `--list window`
adapts conversion results through the same policy; full results remain available.

`RustCandidatePresentation` translates Swift candidates through the stateless C ABI.
Swift still owns consent, stored preference lookup, supplemental personal-vocabulary
and punctuation generation, exact source text, localization and UI state. The bridge
converts Swift Character spans to UTF-8 offsets before merging. Shortlist/leader
comparisons need only consistently ordered source spans. Borrowed strings include
explicit byte lengths, including embedded NUL; result handles own only indices and
metadata and are freed after copying. Invalid metadata falls back to supplied literal
rows in Swift. The app uses statistical ordering plus model rewards; the shared core's
coverage-adjusted mode remains available. Both modes retain the existing coverage
comparison when choosing among duplicate derivations.

Identity normalization uses `unicode-normalization` 0.1.25 from
[unicode-rs](https://github.com/unicode-rs/unicode-normalization), with its locked
`tinyvec` 1.13.3 dependency from [Lokathor](https://github.com/Lokathor/tinyvec).
These are small in-process Unicode utilities, distributed here under their
GPLv3-compatible MIT options. Their upstream MIT notices are preserved under
`crates/si-engine/licenses/` and packaged in `SIEngine/Notices/Engine/`.
Cargo builds the published sources directly; there is no generated vocabulary
or model data. Only complete identity comparison keys are normalized to NFC;
ASCII/basic CJK keys use the guarded borrowed path. Exact output bytes are
never normalized, including when combining marks join across token boundaries.

`InputCandidate.lexicalTokenCount` carries transient lexical evidence independently of identity, score and commit text. Deduplication preserves single-lexical-unit evidence when a stronger composed derivation shares an identity. `rankingScore`/`inputScore` retain base lexical scores; Swift resolves eligible learning/context records into transient statistical scores; Rust combines them with model and consumed-input coverage rewards. `InputSession.presentationScore` exposes the returned score or delegates its coverage calculation to Rust. Keeping coverage outside the decoders leaves same-span terminal/prefix beam selection and automatic-confirmation evidence unchanged. Prefix preferences retain their full capped bonus and never use pending spelling. Punctuation variants embed only the prefix's lexical/preferences score, so coverage is added once during their own merge. Exact personal pins retain their explicit override.

The Rust presentation policy supplies a 27-choice ordinary budget including exact literal input, plus independently pageable generated exact Chinese dictionary characters. Spelling corrections, constructed sentences, multiword fragments and dictionary completions qualify only through the original first four ranked choices across Chinese, English and mixed candidates, subject to the shared output-length budget below and without statistical-leader reservations. A completion counts as constructed even with one lexical unit. At most nine exact word choices, including exact prefixes and explicit personal phrases, are retained in engine order. Chinese dictionary characters and punctuation do not consume this nine-word budget; mixed/verbatim spans do not qualify as ordinary word choices. Words already ranked in the leading four keep their own positions rather than causing lower sentences to be promoted. Every retained nonliteral candidate keeps engine order, with no language reservation; the literal remains last. Both layouts, number shortcuts and mouse actions use the same client-local shortlist. Base lexical scores, coverage rewards, search bounds, committed bytes and candidate identities are unchanged by this presentation restriction.

The window uses one length-based constructed-result budget. Within the original
four-choice head, the first non-word candidate determines the output length using
nonwhitespace Unicode graphemes. Outputs below six characters allow four
constructed choices, six allow three, seven/eight allow two, and nine or more
allow one. Whole sentences, multiword prefixes, corrections and dictionary
completions share that budget in incoming rank order, including single-entry
completions. Exact words, explicit personal phrases and Chinese dictionary
characters keep their existing rules. A word occupying a ranked-head position
does not promote a lower constructed candidate. Original literal input remains
last, and the full engine/Settings result set remains independently available.

This policy inspects existing candidate metadata only. It adds no score-gap,
word-frequency eligibility, contextual-support or completion-stem filters, and
needs no additional decoder/bridge evidence. Lexical scoring, field-context
adjustments, enabled-language identity and source/output bytes keep their existing
contracts. Local model ranking continues to affect incoming order, while the
window adds only a display-count restriction. UI state remains per client.

The controller consumes navigation and number-selection events while composing. `CandidateSelection.action` maps the first Down Arrow while collapsed to expansion without advancing selection, and otherwise maps event key codes/characters to moves or numbered choices; digit lookup reads the active six-column row. Left/Right selects in the collapsed strip and changes columns when expanded. Expanded Up/Down moves by one row across the entire list and scrolls just enough to keep the active row visible. Page Up/Down moves one row when collapsed or up to five rows when expanded, preserving the column where possible. There is no `IMKCandidates` instance or dependency on its selection-key display, identifiers, or callbacks. Out-of-range row numbers do not commit another candidate. Shortcuts retain literal passthrough, and outside composition these keys pass through. Candidate edits/reset invalidate the previous selection. Mouse buttons return candidate identities and use the same current-candidate validation/learning path as digit keys.

The panel never becomes key/main, preserving the host's input focus. The package's `SIPresentation` target compiles the same selection, positioning and AppKit view sources.

In Debug builds, the default-off `debug.candidateGeometryLogging` preference enables one geometry line per placement at `~/Library/Logs/SI/CandidateGeometry.log`. The main actor captures the time, foreground bundle identifier, host ranges, raw probe rectangles, chosen index and display, and final AppKit window frame. A dedicated serial queue formats and appends these records, truncating the existing contents before an append would exceed 2 MB. The disabled writer leaves the file untouched. Secure input and typed content are excluded. See the [positioning checks](TESTING.md#candidate-positioning) for commands.

`CandidateStyle` pairs a neutral background with the solid AppKit control accent and emphasized selection text colors. By default the selection is blue with white text and numbering. The active row uses a subtler accent tint. The system Increased Contrast preference strengthens the card border and outlines the selection. The default 36-point-high strip lays out up to six 28-point candidate buttons horizontally and reserves a trailing expansion chevron with a subtle divider. Each button keeps a compact gap between its number and candidate labels and fits its full text and source symbol, without a fixed per-cell width cap. Extra retained window width does not stretch compact buttons; narrower screens proportionally shrink them without overlapping the chevron. Text-cell insets are included in width measurement; labels with too little room to draw a complete glyph hide rather than clipping through a symbol. Full text remains in accessibility and tooltips. Expanded mode displays up to five six-candidate rows from a continuous vertical list. `CandidateSelection.visibleRange` is the active numbered row. `displayedRange` is the visible portion of the list, and only those candidates have button views. Retained Chinese characters can extend the list beyond the ordinary 27-choice budget. Each row repeats numbers 1–6; only the active row has full-strength numbers and a row highlight. Mouse buttons retain identities across every displayed row, and accessibility help identifies the row and column. Expanded natural width uses the widest visible candidate in each column, including number/source spacing, so lower rows can widen the window beyond the compact strip. All rows share those six column origins and widths, including on narrow screens. The shared columns reserve a minimum number/glyph budget before sharing extra width. Cell content and selection backgrounds fit the candidate within its column rather than stretching short words across a wide slot. Number/text insets follow the shared column width to retain vertical alignment. Tight cells reduce padding and hide source icons while retaining full tooltips/accessibility; preferred widths remain independent of constrained icon visibility. `CandidatePanel` measures against the anchor screen's available width before placement. The collapse chevron stays at the top right. Ordinary word language descriptions are hidden visually; punctuation variants show small E/C badges immediately after the text in both layouts, and their literal fallback shows A (As Typed). Personal, literal and verbatim hints use the same small symbols in both layouts. Prefix consumption and full source descriptions remain in tooltips and accessibility labels. Language identity, full text, exact consumed-input descriptions and selection state remain available in accessibility labels and tooltips. Both layouts render each completed synchronous result with visible shortcut numbers, the same selection and immediately available controls. Wheel and trackpad gestures leave the candidate selection and scroll position in place. Clipping labels never changes committed text.

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

The standalone `si-neural` crate loads exported FP32 weights to run both models
locally. Rust owns Unicode-scalar tokenization, pre-normalized attention,
encoder/decoder generation and conditional candidate scoring. On macOS it uses Accelerate matrix multiplication and the portable implementation provides
a reference without platform libraries. Model exports and parity checks are
described in [the model workspace](../llm/README.md#rust-inference-prototype).
The generator takes explicit syllable paths and optional preceding text. The
character scorer uses a bounded trie to reuse common candidate prefixes.
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
The `corpus/prepare_si_raw_text.py` entry point uses the same extractor to
prepare the three local collections under `chinese/prepared/si-corpus`.

Application dictionary CSV sources and attribution are tracked. The Rust
resource tools prepare snapshots separately from the app build.

`eval/recall/test.jsonl` contains authored recall queries for Rust full search.
Its reports retain every returned candidate before model and window filtering.
`eval/ranking/context.jsonl` and `eval/ranking/context-free.jsonl` use fixed
candidate pools for separate character-LM evaluation. Context contrasts keep
the input and candidate order identical while reversing the preferred output.
The [eval guide](../eval/README.md) documents the execution and provenance.

`eval/ranking/test.jsonl` preserves the historical 220-query suite. It stores authored exact
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

`llm/reranker_small/` implements an independent 7,419,392-parameter causal character-LM baseline: four width-256 pre-norm blocks, four heads, 1,024-wide FFNs, tied embeddings and 256-token context. Its explicit preparation imports verified raw public sources through package-compatible corpus readers, retaining articles/paragraphs, punctuation and English word spaces. Source/group hashes keep Wikipedia pages and conversation turns together; normalized document deduplication and exclusion of cross-split long-paragraph copies reduce exact leakage. Training-only vocabulary, byte fallback and immutable token/window arrays preserve text without joining documents. FP32 training supports strict CPU/MPS resume with RNG/cursor state; CPU is tested bitwise and MPS weights within measured numerical tolerances. Token-loss evaluation, supplied-candidate scoring/benchmarking and inference-only export are separate commands. Bounded validation uses a fixed permutation across source windows. The local 30,000-step checkpoint supports explicit offline Core ML export; the Rust runtime uses the separate FP32 export. Pinyin generation remains an offline experiment. Hard-negative ranking fine-tuning and quantization remain separate work.

The [small reranker chat preset](../llm/reranker_small/README.md#chat-continued-pretraining) sets per-source and per-subcorpus training token quotas, reuses the parent tokenizer and keeps exact parent documents in their original splits. It verifies the local `dialogue` and Chinese Chatbot Corpus extracts, preserves their upstream splits and carries their attribution into the bundle. A new AdamW run starts from compatible model weights and records the parent checkpoint identity. Strict resume still restores optimizer, RNG and cursor within the same run.

`llm/` groups model families into `reranker_small/`, `reranker_large/` and `pinyin_to_text/`. The converter and small offline LM framework are implemented; the large reranker remains planned. Existing converter modules, data/configs, prepared datasets, runs and reports are relocated together, with Python module bytes and checkpoint/data identities preserved. Shared dependencies and `.venv` remain at the workspace root. Compatibility imports plus the `scripts/` and `configs/` links resolve the same conversion implementation; explicit converter commands use `llm.pinyin_to_text.*`. The small reranker's FP32 export supports offline character scoring. Representative ranking quality remains unverified.

The corpus acquisition also supports the latest complete official Chinese Wikipedia current-article dump. Explicit `wikipedia --latest` resolution checks completion metadata, pins a dated URL, verifies the official SHA-1 and records a local SHA-256. The full raw archive retains original simplified/traditional wikitext; streaming preparation selects namespace-0 nonredirect pages and retains page/revision URLs, with Wikipedia's CC BY-SA 4.0 terms kept separate. Existing prepared bundles validate against their own frozen source locks so adding/updating a source does not invalidate historical runs.

The Chinese corpus pipeline extracts full text from pinned public archives and
explicit local collections. It keeps the source locks, text/document ranges and
attribution together. The lexical reading exporter uses the maintained Chinese
CSVs. [Corpus preparation and reading export](../corpus/README.md)

`corpus/english.py` independently acquires and prepares the reviewed English dialogue collection: PersonaChat/ConvAI2, BST, Topical-Chat, Taskmaster 1/2/3, ABCD, SGD and selected English OASST1 messages. It reuses checksum/staged-directory utilities without applying the Han cleaner. Publisher source bytes and full terms are pinned; preparation retains exact selected utterances, original turn/source identity, collection method and existing split membership. Missing upstream assignments stay explicitly unsplit. Alternate ConvAI2 speaker views and non-dialogue metadata are excluded; OASST1 keeps parent edges rather than inventing linear adjacency between replies. Source-separated immutable JSONL bundles carry copied attribution, hashes and measured selection counts. The verifier recounts the whole bundle against its frozen lock. These are acquisition artifacts, not a mixed training dataset or a runtime ranking change; future training still needs deliberate source selection and a broader overlap audit. See [the English guide](../corpus/english/README.md).

`llm/` is a separate Python/PyTorch spelling-to-text framework. Its default is a randomly initialized 19,711,488-parameter encoder-decoder with four encoder and four decoder layers, width 384, eight heads, feed-forward width 1,536 and vocabulary capacity 8,192. The initial budget is 2,000 FP32 steps with batch 16, accumulation 1 and activation checkpointing off. The production Rust candidate engine remains the default macOS path.

The default [syllable CSV collection](../llm/pinyin_to_text/data/syllable-csv/README.md) has 96,000 training, 2,000 validation and 2,000 test rows. Each row provides continuous Pinyin, a target, optional preceding text and an explicit syllable path. A separate deterministic materialization selects lexical rows and contextual cuts from the pinned Chinese dictionary, keeping normalized input/target groups together. The second batch adds 50,000 examples with spellings and targets absent from the first batch. Data preparation checks the declared split membership, syllable reconstruction and model limits, deduplicates within each split and freezes source bytes and hashes with model-ready JSONL.

The encoder separates preceding text from the space-separated syllables with a source-only token. The source and target limits are 96 and 32 tokens. Offline inference batches up to three paths, merges hypotheses by normalized beam score and preserves exact literal fallback. Evaluation keeps references separate per context and shares the annotated paths for a spelling. The held-out rows share the training dictionary's source. Production segmentation and natural sentence quality need separate evaluation. [Contextual Pinyin guide](../llm/pinyin_to_text/README.md#contextual-pinyin-experiment)

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
