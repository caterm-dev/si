# Agent instructions for SI

These instructions apply to the entire repository. Follow more specific instructions in a nested `AGENTS.md` when present. Keep changes focused on the requested task and preserve unrelated work.

## Project and product contract

SI is a macOS input method using Swift, AppKit, InputMethodKit, and SwiftUI. It is currently a development preview with original limited vocabularies, bounded Pinyin/mixed decoding, personal phrases, caret editing, and opt-in Personal Learning. Production vocabulary coverage and host-app compatibility remain unproven.

- Expose one input source. Settings select a set of enabled languages; there is no active-language mode or language-switch shortcut. Shift and Caps Lock must not become language toggles.
- Query every enabled provider for a composition. Keep ambiguous matches from different languages available; ranking must not silently suppress another enabled language.
- Preserve the exact original input as an explicit candidate for every nonempty composition, including unknown words, capitalization, identifiers, and input with all languages disabled. Empty input yields no candidates.
- Keep candidate ordering deterministic. Candidate identity includes language, so identical text from different languages remains distinguishable. The input window may shortlist up to 27 merged results, preserving the exact original input. Chinese, English and mixed candidates qualify by score under the same presentation limits; do not reserve a language's first candidate or first complete word. The engine and Settings preview retain full results.
- Do not present unchecked roadmap items, such as internal pair/sentence context, fuzzy decoding, or broad vocabulary coverage, as implemented features. Keep implemented capabilities and their limits distinct.

Read `README.md`, `CONTRIBUTING.md`, and the relevant sections of `docs/ARCHITECTURE.md` before changing behavior. Use `docs/TESTING.md` for integration checks and `docs/ROADMAP.md` for planned capabilities. Inspect the implementation when documentation and code disagree; report or resolve discrepancies relevant to the task.

## Repository map and boundaries

| Path | Responsibility |
| --- | --- |
| `mac/SI/Core/` | Shared candidate models, providers, merging, and composition state |
| `mac/SI/InputMethod/` | InputMethodKit events, marked text, candidate presentation, and client commits |
| `mac/SI/App/` | Application lifecycle, retained IMKServer, and Settings presentation |
| `mac/SI/Settings/` | SwiftUI settings, enabled-language persistence, and candidate preview |
| `mac/SI/Storage/` | Actor-isolated private learning archive and revision-ordered writes |
| `mac/Support/Info.plist` | Input-source registration and bundle metadata |
| `mac/SI.xcodeproj/` | macOS app target and shared SI scheme |
| `Package.swift`, `Tests/` | Shared core/storage/settings models and Swift Testing tests |
| `Tools/SIBenchmark/` | Synthetic Release-mode candidate-generation measurements |
| `scripts/` | Supported build, test, icon-generation, and local-install entry points |

- The Swift package and Xcode app compile the same core files. Do not create a second engine implementation for the app, preview, or tests.
- Keep the core independent of AppKit, SwiftUI, InputMethodKit, UserDefaults, and application lifecycle. Providers produce candidates; the engine merges them; `InputSession` owns composition state; the controller adapts host events.
- Keep composition state per client session. Do not move buffers or candidate selection into process-wide shared state.
- Persist language preferences through `LanguageSettings`. Do not scatter preference keys or preference reads throughout the core.
- Prefer small changes within these boundaries over new frameworks, generic infrastructure, or unrelated refactors.

## Input-method correctness

- Treat key handling as a host-application contract. Returning `true` consumes an event; returning `false` lets it continue. Avoid dropped keys, duplicate commits, and accidental insertion of control characters.
- Preserve Space/number/mouse selection (including prefix confirmation), Return committing exact remaining spelling, Escape cancelling, and shortcuts retaining literal text. Punctuation/Tab follow `PunctuationBehavior`; never duplicate a key when inserting a replacement. English/code safeguards apply in both candidate-confirming policies. Punctuation candidates are independently opt-in and off by default. Outside composition, mapped common punctuation starts language-labeled candidates only when that option and a language are enabled; other punctuation passes through. Punctuation candidates never train vocabulary/context or append an automatic space.
- Prefix commits consume exact source-character boundaries, including normalized ü/u: spellings and trailing syllable separators, and leave the rest marked/editable. Do not append an English space while a remainder is pending. Whole candidates and prefixes compete using only the spelling each candidate consumes. Do not estimate pending-suffix conversions, charge extra prefix confirmation costs or scale prefix preferences by total input length; only consumed spelling can receive prefix learning/context preferences. Do not reserve leading positions by whole/prefix status, consumed length, lexical-unit count or word/character type. The input window preserves engine order when shortlisting; explicit personal pins retain their own contract.
- Keep prefix scores independent of the pending remainder. Apply whole/prefix and eligible previous-word preferences before their presentation limits, using only consumed source spelling for prefixes. Preserve bounded terminal base/personalized alternatives and two distinct prefix results per language combination/span; low-cost direct paths must not erase higher-scoring equivalent composed candidates. Prefix commits and automatic-confirmation evidence must validate exact source and output-byte boundaries, preserve explicit spelling separators and aliases, remain bounded and avoid persisting hypothetical suffixes.
- Keep buffer, marked text, selected candidate, and candidate-window visibility consistent after edits, commits, cancellation, configuration changes, and focus changes. Stale selections must not replace current input.
- Use UTF-16 offsets for AppKit/InputMethodKit `NSRange` values. Do not substitute Swift character counts for UTF-16 lengths. Keep user-visible deletion character-aware.
- Preserve composition-caret editing, including scalars that join into graphemes. Left/Right and Home/End edit marked text; Up/Down and page keys navigate the client-local candidate selection. The nonactivating AppKit window, displayed numbers, mouse clicks, and keyboard confirmation must use that same page/index without taking host focus. Navigation outside composition must break previous-word context.
- Candidate labels are presentation data. Commit only candidate text, without language labels or other UI decoration.
- Retain the `IMKServer` for the process lifetime. Closing Settings must not terminate the input-method server.
- Keep the Objective-C name `SIInputController`, the controller entry in `Info.plist`, the connection name, and bundle settings consistent. Registration changes require explicit consideration of existing installations.

## Concurrency and responsiveness

- Use Swift 6 language mode and preserve explicit actor isolation. UI and mutable controller state belong on the main actor.
- The existing Objective-C callback bridge uses `MainActor.assumeIsolated`, narrowly scoped `nonisolated(unsafe)` locals, and `@unchecked Sendable`. These rely on InputMethodKit's callback threading behavior; they are not general solutions to concurrency errors. Do not expand their use without documenting and validating the isolation assumption.
- Keep the keystroke path responsive. Do not add synchronous file access, dictionary loading, model initialization, or other expensive work to each key event.
- If asynchronous candidate generation is introduced, reject results from obsolete compositions or client sessions, and prevent delayed results from restoring cancelled state. Add focused regression coverage.
- Do not invent a latency target or claim a performance improvement without measurements. Use synthetic input for profiling.
- Comparison/hash optimizations must preserve canonical identity, deterministic order, and exact committed bytes. Preserve the guarded ASCII/CJK comparison path and Unicode fallback; do not normalize output text or assume normalization stops at token boundaries.

## Privacy, dependencies, and data

- Input is sensitive. Do not put input/committed text in diagnostic logs or transmit it. Only the separately opted-in Input History feature may persist successful SI submissions, including exact literal/personal/verbatim text. Never collect raw keystroke events, unconfirmed compositions, cancelled text, host documents, clipboard or passthrough text outside SI. Do not add analytics or remote inference. Use synthetic examples in tests and reports.
- AI ranking, native model inference and input-field context readback are retired pending redesign. Keep runtime ranking on the existing dictionary-frequency and opted-in Personal Learning engine; do not read preceding host text or retain cross-composition drafts.
- Personal Learning requires an independent opt-in, off by default, and shares one global profile across eligible apps. Use the IMK client's bundle identifier for the independent direct-input boundary, never the foreground process; Personal Learning has no app scope or per-app controls. Remove the retired per-app learning exclusion key without changing existing learning consent. Count first/nonfirst confirmations as usage, but do not raise ranking strength or change remembered selection for a displayed first choice (including number/mouse selection). One explicit nonfirst choice becomes the first ordinary candidate for the next exact normalized whole spelling; newer corrections replace it, and explicit personal pins retain priority. Do not force-prefix/completion placement for shorter/longer input. Every three nonfirst choices also add one frequency point with a 32-point cap. Neither app-learning strength nor records decay or expire with age. Retain at most 5,000 global records with deterministic least-recently-used capacity eviction. Preserve the global learning switch, per-entry/global deletion, secure-input suppression and storage-error feedback. Do not restore per-app learning pause, deletion, clear or filtering. The former App History draft/completion feature remains retired: no source/output draft buffers, Return-delimited passthrough units or history completions. The independent Input History below records only SI submissions. Schema-1/2/3 app archives migrate atomically to global vocabulary-only schema 4 at the existing path, dropping app identity/history, merging bounded counts and maximum strength, retaining schema-3 ranking evidence and neutralizing older ambiguous evidence. Do not invent selection markers from old last-use timestamps. Failed decoding preserves the original file. Old history consent/exclusion keys cannot enable vocabulary and are removed. Do not read documents or clipboard content.
- Input History is separate from Personal Learning, with its own default-off `inputHistory.enabled` consent. Save one record per successful SI composition submission: exact consumed source, exact submitted output (including SI-inserted suffix), timestamp, event UUID, language/mixed identity and commit reason. Preserve repeated submissions and raw casing/aliases; prefixes exclude the pending remainder. Include explicit/default/automatic/literal/punctuation/personal-phrase commits, but not cancelled composition, empty commits, secure input, direct-input app text or keys passed through outside composition. Check consent/secure input before and after host insertion; use consent generation to reject reentrant changes. Store records indefinitely without age/count eviction in the independent owner-only `SI/InputHistory/history-v1.sqlite3`, with actor-isolated SQLite I/O, bounded keyset pages, parameterized queries, idempotent retry, visible errors and explicit per-entry/all deletion. Clear must invalidate older queued records and pending retries. No history completions, ranking, automatic training, archive migration from retired App History or network use are implied. One user-selected JSONL export supports restoration and offline candidate preparation, without purpose choices or training-permission flags; preserve full snapshot bytes/count/checksum and never send it automatically. Receiver restore/CSV preparation is offline and accepts the same export without a purpose/permission gate. Keep received/derived private data ignored by Git; do not infer gold labels, source rights, train/evaluation splits or start training. Existing language/learning/old-history flags cannot enable recording. Do not silently drop failed writes; pause new recording and expose retry or clear recovery. Flush accepted queued writes on normal termination; forced termination or unretried storage failures may lose unsaved records.
- The former separate Personal learning archive and previous-word pair product options remain retired. Do not restore that archive or use old consent flags to enable current global vocabulary. Old `preferences-v1.json` files are not loaded, migrated or automatically deleted; preserve the separate explicit legacy-delete control and its error feedback. Core ranking/context APIs may remain for library fixtures, including their historical decay policy, but product vocabulary uses persistent noncontextual preferences. Never treat enabling a language as consent to recording.
- Explicit personal phrases retain until user deletion, with a 1,000-entry cap. Keep them separate from learned preferences and exclude them from automatic learning/context. Imports must validate atomically, preserve local data, respect size/capacity limits, and not apply over intervening edits or clear. Export requires a user-selected destination; exported text is personal data.
- Exclude every derived path containing personal phrases or unrecognized verbatim spans from learning/context. Learn only consumed spelling after prefix selection, never the pending remainder. Delimiter confirmations do not train.
- Reuse existing single-language frequency records for token ranking without automatically saving decomposed sentence tokens. Length-weighted token and whole-input preferences share a 32-point cap using their maximum, with at most 12 additional previous-word points. Preserve base and personalized search beams; disabling learning, secure input, deletion, capacity eviction, and clear must also stop token effects.
- Preserve bounded lattice states, cached immutable candidate IDs, fractional ranking, explicit transition costs, personal-node fanout, and the 4,096-byte constructed-output bound. All direct lexical/personal matches and exact literal fallback remain independently available.
- Keep persistence off the main actor and key-event path. Older queued writes must not undo newer deletions. User dictionaries and any extension to retained data require an explicit retention/deletion design within the requested scope.
- Optional Accessibility and Screen Recording requests are explicit Settings actions for future user-authorized experiments. Permission grants do not change input behavior, enabled languages, learning or history. AX control-tree inspection, automatic field-based input rules and screenshot collection remain unimplemented; the opted-in IMK model-context read has the narrow boundary above. Do not request permissions automatically while typing, add Input Monitoring/global event taps, or add app-specific field detection. Normal SI conversion and application-wide direct input require neither permission.
- App Sandbox is currently disabled for the legacy InputMethodKit connection. Do not enable it as an unrelated hardening change; any change must validate server/client communication.
- Preserve the repository's GPLv3 license. Before introducing a third-party engine, dictionary, model, or large dependency, follow the discussion requirement in `CONTRIBUTING.md` unless the user has already explicitly authorized that choice. Document origin, version, license compatibility, redistribution rights, and any generated-data steps. Do not assume installed system dictionaries can be redistributed.

## Build and validation

The documented toolchain is macOS 14+, Xcode 26+, and Swift 6.2+. The package tests use Swift Testing, not an Xcode test target. Run commands from the repository root:

```sh
./scripts/test.sh                         # All shared-core tests
./scripts/test.sh --filter InputSessionTests  # Focused composition tests
./scripts/build.sh                       # Debug app, signing disabled
./scripts/build.sh Release               # Release app; also built by CI
./scripts/benchmark.sh                   # Synthetic in-process engine timings
```

- For code changes, run `./scripts/test.sh` and `./scripts/build.sh`; use the Release build when changing release configuration or preparing distribution. CI runs core tests and a Release build.
- Add focused tests for changed core behavior and regressions. Relevant cases include ambiguous input, disabled languages, literal preservation, deterministic ordering, language-aware deduplication, normalization, editing, stale selections, and commit/reset transitions. Avoid tests that merely repeat implementation details.
- InputMethodKit, event routing, actor callback assumptions, candidate positioning, and host compatibility require relevant manual checks from `docs/TESTING.md`. Core tests and a successful build do not establish runtime compatibility.
- For input-method behavior changes, exercise synthetic input in representative host apps, including focus changes and shortcuts. For candidate/settings UI changes, check keyboard use, VoiceOver, and appearance as relevant. Record what was actually verified and what remains unverified.
- Documentation-only changes need link, command, and consistency checks; do not run builds or install the input method solely for a prose edit.
- If the toolchain or login session is unavailable, report the limitation precisely. Do not claim a check passed or change product behavior merely to satisfy an unsuitable environment.

## Local installation and system state

- Build products are under `.build/xcode/Build/Products/<configuration>/SI.app`. The Xcode Run scheme passes `--settings` to open Settings.
- Use `./scripts/install.sh` when local installation is part of the requested task. It builds, stages and verifies an ad hoc signed app, backs up an existing installation, and installs to `~/Library/Input Methods/SI.app` without `sudo`.
- Installation is not a prerequisite for ordinary code or documentation edits. Do not modify the user's enabled input sources, force logout, or kill input-method processes as a routine verification step.
- Respect the installer's running-process guard and backup/rollback behavior. Do not bypass them to replace an active input method.
- Do not run built and installed copies together: they share an InputMethodKit connection name. Registration may require the user to log out and back in; report that requirement instead of forcing it.
- Keep personal signing teams, certificates, provisioning profiles, secrets, Xcode user state, caches, and build outputs out of commits. Preserve the default local ad hoc signing setup unless signing changes are requested.

## Style and handoff

- Follow `.editorconfig` and nearby Swift conventions. Use English for identifiers, comments, documentation, UI copy, commit messages, issues, and pull requests. Language data and input examples retain their native scripts. Reply to the user in their preferred language.
- Use installed SDK headers to verify imported InputMethodKit signatures. Consult official Apple documentation when needed; do not guess Objective-C callback names or silently weaken compiler checks.
- When adding a language, update its stable identifier/display name, provider registration, enabled preference and Settings UI, tests, and data provenance documentation together. Avoid changing existing persisted identifiers without a migration plan.
- Update `README.md` and relevant architecture/testing documentation when behavior, setup, or verification changes. Keep roadmap claims accurate.
- Before handing off, inspect the diff for unrelated changes and accidental sensitive data. Summarize the resulting behavior, checks actually run, and remaining limitations. Do not commit, publish, or install unless the task calls for it.
