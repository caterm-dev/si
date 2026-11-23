import Foundation
#if SWIFT_PACKAGE
import SICore
#endif

/// Acceptance decoration stays separate from candidate bytes and learning evidence.
struct CandidateSpacing {
    let prefix: String

    init(commit: InputCommit, before: String? = nil) {
        func isEnglish(_ scalar: Unicode.Scalar?) -> Bool {
            scalar.map { $0.isASCII && CharacterSet.letters.contains($0) } == true
        }
        let previous = before?.last?.unicodeScalars.first
        let first = commit.text.unicodeScalars.first
        let changesScript = (previous?.properties.isIdeographic == true && isEnglish(first))
            || (isEnglish(previous) && first?.properties.isIdeographic == true)
        prefix = commit.candidate?.isPunctuation != true && changesScript ? " " : ""
    }
}
