# Agent instructions for SI

These instructions apply to the entire repository. Follow more specific instructions in a nested `AGENTS.md` when present. Keep changes focused on the requested task and preserve unrelated work.

## Project and product contract

SI is a macOS input method using Swift, AppKit, InputMethodKit, and SwiftUI. It is currently a development preview with original limited vocabularies, bounded Pinyin/mixed decoding, personal phrases, caret editing, and opt-in frequency/short-context learning. Production vocabulary coverage and host-app compatibility remain unproven.

- Expose one input source. Settings select a set of enabled languages; there is no active-language mode or language-switch shortcut. Shift and Caps Lock must not become language toggles.
- Query every enabled provider for a composition. Keep ambiguous matches from different languages available; ranking must not silently suppress another enabled language.
- Preserve the exact original input as an explicit candidate for every nonempty composition, including unknown words, capitalization, identifiers, and input with all languages disabled. Empty input yields no candidates.
- Keep candidate ordering deterministic. Candidate identity includes language, so identical text from different languages remains distinguishable. The input window may shortlist up to 27 merged results, preserving the engine's first candidate per single-language/mixed identity and the exact original input; the engine and Settings preview retain full results.
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
- Preserve Space/number/mouse selection (including prefix confirmation), Return committing exact remaining spelling, Escape cancelling, and shortcuts retaining literal text. Punctuation/Tab follow `PunctuationBehavior`; never duplicate a key when inserting a replacement. English/code safeguards apply in both candidate-confirming policies. Outside composition, punctuation passes through.
- Prefix commits consume exact source-character boundaries, including normalized ü/u: spellings and trailing syllable separators, and leave the rest marked/editable. Do not append an English space while a remainder is pending. Whole candidates precede prefixes in the engine. The input window may feature its first two whole choices followed by up to seven high-scoring prefixes within that shortlist; short words must not displace those first whole choices.
- Keep continuation costs separate from presentation scores. Apply whole/prefix and eligible previous-word preferences before their presentation limits, using only consumed source spelling for prefixes. Preserve bounded terminal base/personalized alternatives and two distinct prefix results per language combination/span; low-cost direct paths must not erase higher-scoring equivalent composed candidates.
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

- Input is sensitive. Do not log or transmit composition text, committed text, surrounding client text, or keystrokes. Outside the separately opted-in app history described below, do not persist arbitrary literal input or chronological input history. Do not add analytics or remote inference. Use synthetic examples in tests and reports.
- App vocabulary and app history require independent opt-ins, both off by default. Scope records to the IMK client's bundle identifier, never the foreground process. Vocabulary counts explicit/default confirmations and retains bounded aggregate preferences for 90 days; history deduplicates Return-delimited input units for 30 days (5,000 vocabulary and 1,000 history entries across apps). Preserve per-app pause, per-entry deletion, scoped/all clear, secure-input suppression, and storage-error feedback. History is the explicit exception permitting literal text retention, not a per-keystroke log or permission to read documents/clipboard. Pending history stays client-local, expires after five minutes, and is discarded on edits to committed text, shortcuts, focus/configuration/consent boundaries, automatic confirmation, and personal/verbatim paths. History completion must not train vocabulary/context or duplicate committed prefixes.
- Explicitly enabled personal learning may persist bounded aggregate input-to-language-candidate preferences locally. It is off by default, decays with time, expires after 90 days without use, and is capped at 5,000 entries. Preserve pause, per-entry deletion, clear, secure-event suppression, and storage-error feedback. Never treat enabling a language as consent to learning.
- Previous-word pairs require a separate opt-in and share learning capacity/expiry. Keep the prior candidate client-local for at most five minutes, exclude personal/literal candidates, and clear eligibility on focus/cancel/host boundaries, language changes, consent changes, and clear. Do not read surrounding document text. Preserve schema-1 learning migration to schema 2.
- Explicit personal phrases retain until user deletion, with a 1,000-entry cap. Keep them separate from learned preferences and exclude them from automatic learning/context. Imports must validate atomically, preserve local data, respect size/capacity limits, and not apply over intervening edits or clear. Export requires a user-selected destination; exported text is personal data.
- Exclude every derived path containing personal phrases or unrecognized verbatim spans from learning/context. Learn only consumed spelling after prefix selection, never the pending remainder. Delimiter confirmations do not train.
- Reuse existing single-language frequency records for token ranking without automatically saving decomposed sentence tokens. Length-weighted token and whole-input preferences share a 32-point cap using their maximum, with at most 12 additional previous-word points. Preserve base and personalized search beams; pause, secure input, deletion, expiry, and clear must also stop token effects.
- Preserve bounded lattice states, cached immutable candidate IDs, fractional ranking, explicit transition costs, personal-node fanout, and the 4,096-byte constructed-output bound. All direct lexical/personal matches and exact literal fallback remain independently available.
- Keep persistence off the main actor and key-event path. Older queued writes must not undo newer deletions. User dictionaries and any extension to retained data require an explicit retention/deletion design within the requested scope.
- SI does not request Accessibility or Input Monitoring permission or use a global event tap. Do not add these to work around a local integration bug.
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
