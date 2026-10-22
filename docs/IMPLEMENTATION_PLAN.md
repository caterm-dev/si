# Chinese engine refactor — current objective

User direction, 2026-10-21: implement MSIME's Chinese core in Swift, maintain an SI dictionary derived from its data, and establish Chinese conversion quality before adding English mixed lexical paths. Do not link Rust. The original code-only restriction was lifted by the user on October 22, 2026; validation is now authorized. Existing consent, deletion, client isolation and exact-source commit rules remain in force.

The user subsequently confirmed that the reference MSIME installation uses default settings with no extra features enabled. The required baseline is therefore the default word-lattice and word-ngram pipeline. Optional neural reranking and general autocorrection remain future capabilities rather than prerequisites for this baseline; fixed spelling aliases still participate by default.

## Implementation and remaining work

| Component | Current state | Completion evidence still required |
| --- | --- | --- |
| Native Swift core | Read-only lexical lookup, canonical syllables, per-chunk primary/alias segmentation, word lattice, streaming heap beam selection, terminal libc++ introsort tie movement and word bigram/trigram rescoring written and connected to the default engine | Compilation and comparison with the pinned MSIME implementation are deferred |
| SI-owned dictionary | Compressed pinned sources, source hashes, reading corrections, SI additions/exclusions overlay and read-only SQLite resource generator written; packaged dictionary generated | Reproducibility and source/data comparison are deferred |
| Exact candidate placement | Chinese provider order preserved across engine merge; exact words precede constructed sentences and completions | Word-level comparison, ambiguity and learning checks are deferred |
| Source boundary editing | Existing session revision/caret/commit pipeline retained; new decoder maps prefixes through normalized source boundaries | Unicode, apostrophes, prefix commits and native host checks are deferred |
| Personal data | Existing SI stores and consent remain authoritative; saved codes supplement the default reading rather than replacing it, direct prefixes retain all saved choices, and personal nodes respect typed boundaries and remain excluded from learning/context | Private-profile and storage regression checks are deferred |
| Correction and sparse lookup | Fixed spelling aliases, full/prefix/mixed-initial cascade, bounded retroflex-initial splitting and sparse dictionary fallbacks written with typed-source spans; default alternative-cut gates, per-table 128-row pages and merge/dedup sequence aligned in source | New lookup behavior remains unverified; general autocorrection is outside the confirmed default baseline |
| Optional neural reranking | Not migrated; disabled in the confirmed reference configuration | Future capability; not required for default baseline parity |
| English | Existing lookup/English word composition retained; English now uses the same weighted-snapshot, SI-overlay, SQLite schema, reader and relative-frequency unit as Chinese | Mixed lexical paths and complete cross-language sentence-score calibration remain separate work; no quality claim is made |
| App/Settings packaging | Package resource declaration and default core facade changed; Xcode shares the same Swift sources/resources | Compiler, bundle and native host checks are deferred |
| Quality parity | Unproven | After authorization to run checks, compare pinned resources and isolated profiles, then independent word/sentence and native host cases |

The current changes pass Debug/Release compilation and focused migration checks, but the complete regression suite and Chinese quality still fail. This is not a completed parity milestone. The October 22 record in `docs/VERIFICATION.md` supersedes the deferred-check states in the table above. The user's `ne` and `julitebieyuan` examples are known development cases and cannot serve as independent quality evaluation. No per-word special-case scoring has been introduced.

## Historical checkpoint before the refactor

# Daily-use input method implementation

Objective: complete SI as a reliable macOS input method, including personal learning. A passing core suite alone does not establish completion.

## Constraints

- One input source, enabled-language set, combined candidates, exact literal fallback.
- Local processing, no text logs, no remote inference or telemetry.
- Historical decision (2026-10-18), superseded on 2026-10-21: original vocabularies only. The user now explicitly authorizes MSIME-derived Chinese algorithms and dictionary data.
- Explicitly enabled learning may retain aggregate input-to-candidate preferences locally. Users must be able to pause learning, remove entries, and clear the store. No automatic collection of arbitrary literal input.
- Previous-word pairs require a separate opt-in, share the learning capacity/expiry policy, and use only bounded client-local context. Explicit personal phrases retain until deletion with a separate 1,000-entry cap and additive, validated import/export.

## Work and evidence

| Requirement | Required evidence | Status |
| --- | --- | --- |
| Personal frequency/recency ranking | Deterministic tests including competing languages, stale choices, decay, and weak/strong feedback | Implemented and tested; native event feedback still needs verification |
| Durable local learning | Restart, atomic-write, malformed-data, retention, deletion, and pending-write ordering tests | Implemented and tested; full model/store lifecycle covered |
| Learning controls | Opt-in, pause, entry deletion, clear, error feedback, accessible settings UI and manual verification | Implemented; model tests pass, UI inspection blocked by offline Caterm |
| Pinyin decoding and editing | Syllable boundaries, apostrophes, partial input/commits, phrase construction, full/initial combinations, and normalization tests | Bounded decoder, prefix confirmation, and caret editing implemented/tested; native remainder handling remains unverified |
| Continuous mixed-language input | Segmentation, final-word completion, unknown spans, ambiguity, and literal-preservation tests | Implemented within bounded lexical heuristics; general language-boundary detection remains limited |
| Useful original vocabularies | Documented original data, realistic held-out inputs, vocabulary coverage review | 979 Chinese alternatives and 638 English words; ten held-out synthetic sentences pass. Independent evaluation and broad coverage remain pending |
| Composition punctuation | Configurable policy, English/code safeguards, no duplicate keys or delimiter learning | Core policy and persistence tested; native routing remains unverified |
| Host event correctness | Focus/client isolation, shortcuts, punctuation, digits, marked-text ranges, stale callbacks, and native navigation checks | Pending |
| User dictionary and short-context adaptation | Explicit phrase management, lattice nodes, persistence, session boundaries, deletion tests and UI | Implemented with codec/model/storage/lattice tests; native dialogs and focus behavior remain unverified |
| Learned token ranking in longer compositions | Decaying preferences influence internal alternatives without bypassing consent, language, and privacy bounds | Implemented with base/personalized beams, shared cap, deletion/expiry/restart/secure-input tests; limited vocabulary-derived character-boundary context is implemented; broader sentence models remain pending |
| Performance and robustness | Repeatable synthetic benchmarks, memory checks, corrupt-store recovery, and long-composition tests | Thirteen-scenario Release benchmark, output fingerprints, exhaustive small-search checks and CLI resources measured; guarded comparison/hashing improve long ASCII/CJK expansions, Unicode/emoji expansions and native/broader coverage remain pending |
| Accessibility and host compatibility | TextEdit, browser, editor, Terminal, office apps, VoiceOver, dark mode, displays | Pending; requires real login-session checks |
| Distribution and recovery | Release build, installer backup/rollback checks, signing/notarization strategy and documentation | Pending; release credentials are not part of the repository |
| Accurate public documentation | README, architecture, testing, roadmap, privacy and agent guidance describe actual behavior | Updated for this checkpoint; keep current as remaining work lands |

Record completed commands and remaining checks as implementation progresses. Do not replace missing integration evidence with build results or mark this objective complete while required behavior remains unverified.

## Current checkpoint

See `docs/VERIFICATION.md` for the latest tests and builds. Personal phrases support add/edit/delete/pin, additive JSON import/export, private persistence, secure-event suppression, and intermediate lattice nodes. Optional previous-word learning has separate consent, shared retention/deletion controls, client-local timeout/reset logic, and legacy-store migration. Existing word preferences now influence internal lattice tokens with a shared 32-point cap, preserving a separate base beam and adding no retained fields or automatic token harvesting. Composition editing handles a whole-character caret with UTF-16 marked offsets, including joining scalar sequences. Prefix selection consumes exact source boundaries and retains an editable remainder. Configurable punctuation has conservative English/code safeguards and never trains learning.

The latest synthetic Release benchmark includes 5,000 learned records and 1,000 personal phrases across thirteen cases. Guarded comparison/hashing reduced the long ASCII expansion case from 27.584 to 11.095 ms p95 while matching fingerprints across all twelve existing cases. The added Unicode/emoji case measures 30.727 ms p95 and remains an optimization priority. Peak CLI resident memory is 30.16 MiB and peak footprint 24.11 MiB for this larger workload. See `docs/VERIFICATION.md` for measured scope; native UI/host latency and memory remain unproven.

Authorized SI-only inspection is still unavailable: the latest targeted read timed out, and a follow-up returned a connection-availability notice without app state. No broader app inventory or alternate control backend was used. The objective remains active. Next independent priorities include Unicode expansion/search performance, broader original vocabulary/independent quality evaluation, fuzzy decoding, broader sentence modeling, and distribution recovery. Native UI/client verification remains a separate unmet gate; builds and pure tests do not satisfy it.
