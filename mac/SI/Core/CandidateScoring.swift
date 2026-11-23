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

    static func inputCoverageBonus(for candidate: InputCandidate, spelling: String) -> Double {
        RustCandidatePresentation.coverageBonus(for: candidate, spelling: spelling)
    }

    static func personalCost(codeLength: Int, typedLength: Int, pinned: Bool) -> Double {
        (wordInsertionCost - frequencyWeight * log(Double(personalWeight))) / log(2.0) - (pinned ? 1 : 0)
            + WordPrefixChannel.cost(fullLength: codeLength, typedLength: typedLength)
    }
}
