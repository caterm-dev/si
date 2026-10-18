# Architecture

## Product contract

SI exposes one macOS input source. Settings contain a set of enabled languages, not an active language. Every enabled provider is queried for the current composition. Matching candidates coexist; ambiguity is a choice for the user rather than a reason to switch modes. Literal input is always offered.

## Data flow

```text
Host application key event
  → SIInputController
  → InputSession (buffer and enabled languages)
  → CandidateEngine
  → all enabled CandidateProvider implementations
  → deterministic merged candidates + literal fallback
  → native IMKCandidates window
  → committed text in the host application
```

`CandidateEngine` and `InputSession` are value types with no UI or persistence dependencies. Providers implement `CandidateProvider` and return text, language identity, and a demo ranking score. The engine removes duplicate identities within a language, sorts by score with a stable identity tie-break, and appends an original-text candidate. It does not globally cap results.

Current scores prefer exact English matches over exact Pinyin matches, then English completions. This is deliberately transparent scaffolding, not a trained ranking model. Provider scores will need a common calibration contract before production engines are added.

`InputSession` owns one composition, refreshes candidates after edits or configuration changes, rejects stale candidate commits, and clears itself after a commit or cancellation. A separate controller exists for each InputMethodKit client session.

## macOS integration

`SIApplication` starts an AppKit application. `AppDelegate` retains one `IMKServer` for the process lifetime. `mac/Support/Info.plist` names the connection and the stable Objective-C controller class `SIInputController`; it registers a single input source with no mode dictionary. The primary discovery language is Simplified Chinese, while the character repertoire includes Latin and Simplified Chinese scripts.

`SIInputController` adapts key events to the core, maintains marked text in the client, and uses `IMKCandidates` for native selection, scrolling, and positioning. Each displayed row includes an English language label or “As Typed”; the adapter resolves that row back to its candidate and commits only the candidate text. Objective-C callbacks lack Swift actor annotations. The UI callback boundary uses `MainActor.assumeIsolated` explicitly; this relies on InputMethodKit delivering those callbacks on the main thread. Non-Sendable Objective-C callback arguments are captured using narrowly scoped `nonisolated(unsafe)` locals, and the controller explicitly declares `@unchecked Sendable` while its mutable state stays main-actor isolated. This boundary must be exercised during manual integration checks.

App Sandbox is disabled because the legacy InputMethodKit server uses interprocess connections with text clients. SI does not request Accessibility or Input Monitoring permissions and does not install a global event tap. `LSUIElement` keeps the input-method process out of the Dock. Closing Settings does not terminate the server.

`LanguageSettings` is main-actor-isolated and observable. It persists only the enabled-language booleans in the application's defaults domain. Both languages default to enabled. Settings take effect when the next key event refreshes a composition. Disabling all languages leaves literal input available. Shift and Caps Lock do not select a language mode.

The Xcode Run scheme passes `--settings`; normal system launches keep the process in the background. The installed app exposes Settings through the input menu and on reopening the app.

## Extending language support

1. Add a stable language identifier and English display name to `InputLanguage`.
2. Implement a `CandidateProvider` with local, deterministic behavior and licensed data.
3. Register the provider in `CandidateEngine` and expose its enabled preference in Settings.
4. Test ambiguous sequences, disabled-language filtering, deterministic ranking, literal fallback, and composition resets.
5. Document dictionary provenance, performance characteristics, and limitations.

The demo Pinyin provider performs exact lookup after lowercasing and removing apostrophes. It does not implement syllable decoding, abbreviated input, tone handling, phrase segmentation, or learning. The English provider uses a small original prefix vocabulary. Neither provider uses system Chinese dictionaries or downloads external data.

## References

- [Apple: IMKServer](https://developer.apple.com/documentation/inputmethodkit/imkserver)
- [Apple: IMKServerInput](https://developer.apple.com/documentation/inputmethodkit/imkserverinput)
- [Apple: IMKCandidates](https://developer.apple.com/documentation/inputmethodkit/imkcandidates)

The installed SDK headers are the source of truth for imported Swift method names and callback signatures.
