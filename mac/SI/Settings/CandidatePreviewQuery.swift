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
}
