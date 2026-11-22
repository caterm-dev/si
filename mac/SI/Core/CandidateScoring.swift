import Foundation

/// Presentation rewards and direct personal-phrase fallback costs.
enum CandidateScoring {
    static let initialLanguageCost = 1.0
    static let personalWeight: Int64 = 10_000
    // Retained insertion priors; these are not corpus probabilities.
    private static let wordInsertionCost = 20.0
    /// Amplify dictionary-frequency differences relative to insertion and spelling costs.
    /// Known synthetic fixtures favor this over 1.10; it is not a probability estimate.
    private static let frequencyWeight = 1.05

    /// Presentation reward per matched source letter/digit, selected on authored fixtures.
    /// Independent of output length, lexical splits and any unconsumed continuation.
    private static let inputCoverageWeight = 5.0

    static func inputCoverageBonus(for candidate: InputCandidate, spelling: String) -> Double {
        // Only dictionary-aligned spelling earns coverage.
        guard !candidate.isLiteral, !candidate.hasLiteralSegments else { return 0 }
        return Double(coverageUnitCount(in: spelling)) * inputCoverageWeight
    }

    static func coverageUnitCount(in spelling: String) -> Int {
        // Apostrophes and punctuation earn nothing; ü, v and u: each count once.
        spelling.unicodeScalars.reduce(0) { count, scalar in
            switch scalar.value {
            case 65...90, 97...122, 48...57, 0xFC, 0xDC: count + 1
            default: count
            }
        }
    }

    static func personalCost(codeLength: Int, typedLength: Int, pinned: Bool) -> Double {
        (wordInsertionCost - frequencyWeight * log(Double(personalWeight))) / log(2.0) - (pinned ? 1 : 0)
            + WordPrefixChannel.cost(fullLength: codeLength, typedLength: typedLength)
    }
}
