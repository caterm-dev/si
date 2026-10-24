import Foundation
#if SWIFT_PACKAGE
import SICore
#endif

/// Immutable preview configuration; changing consent or dictionary data invalidates old work.
struct CandidatePreviewQuery: Equatable, Sendable {
    let input: String
    let languages: Set<InputLanguage>
    let learning: LearningProfile
    let dictionary: UserDictionary
    let applicationMemory: ApplicationMemorySnapshot
    let punctuationCandidatesEnabled: Bool

    init(input: String, languages: Set<InputLanguage>, learning: LearningProfile, dictionary: UserDictionary,
         applicationMemory: ApplicationMemorySnapshot = .empty, punctuationCandidatesEnabled: Bool = false) {
        self.input = input
        self.languages = languages
        self.learning = learning
        self.dictionary = dictionary
        self.applicationMemory = applicationMemory
        self.punctuationCandidatesEnabled = punctuationCandidatesEnabled
    }
}
