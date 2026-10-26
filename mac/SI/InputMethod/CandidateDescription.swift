import Foundation
#if SWIFT_PACKAGE
import SICore
import SILocalization
#endif

/// Localizes presentation metadata without changing core identity or committed text.
enum CandidateDescription {
    static func label(for candidate: InputCandidate, bundle: Bundle = L10n.bundle) -> String {
        let language: String
        if let punctuation = candidate.punctuationLanguage {
            language = L10n.text(punctuation == .english ? "English Punctuation" : "Chinese Punctuation", bundle: bundle)
        } else if candidate.isMixed {
            language = L10n.text(candidate.hasLiteralSegments ? "Chinese + As Typed" : "Chinese + English", bundle: bundle)
        } else {
            language = L10n.text(candidate.language?.displayName ?? "As Typed", bundle: bundle)
        }
        let source: String
        if candidate.isHistory {
            source = L10n.text("App History", bundle: bundle)
        } else if candidate.isApplicationVocabulary {
            source = L10n.format("App Vocabulary · %@", language, bundle: bundle)
        } else if candidate.isUserPhrase {
            source = L10n.format("Personal · %@", language, bundle: bundle)
        } else {
            source = language
        }
        return candidate.consumedInputCount.map {
            L10n.format("First %ld characters · %@", $0, source, bundle: bundle)
        } ?? source
    }
}
