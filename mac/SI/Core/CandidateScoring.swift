import Foundation

/// Shared heuristic lexical costs and presentation rewards in bits.
/// These scores are comparable across decoders; they are not calibrated probabilities.
enum CandidateScoring {
    static let pointsPerBit = 1.0
    static let terminalCost = 0.0
    static let initialLanguageCost = 1.0
    static let personalWeight: Int64 = 10_000
    // Retained insertion priors; these are not corpus probabilities.
    private static let wordInsertionCost = 20.0
    private static let characterInsertionCost = 2.0
    private static let englishWordInsertionCost = 3.0
    /// Amplify dictionary-frequency differences relative to insertion and spelling costs.
    /// Known synthetic fixtures favor this over 1.10; it is not a probability estimate.
    private static let frequencyWeight = 1.05

    /// Presentation reward per matched source letter/digit, selected on authored fixtures.
    /// Independent of output length, lexical splits and any unconsumed continuation.
    private static let inputCoverageWeight = 5.0

    static func inputCoverageBonus(for candidate: InputCandidate, spelling: String) -> Double {
        // Verbatim spans are preserved for selection, but are not lexical matches.
        guard !candidate.isLiteral, !candidate.hasLiteralSegments else { return 0 }
        let length = spelling.unicodeScalars.reduce(0) { count, scalar in
            switch scalar.value {
            case 65...90, 97...122, 48...57, 0xFC, 0xDC: count + 1
            default: count
            }
        }
        // Apostrophes and punctuation earn nothing; ü, v and u: each count once.
        return Double(length) * inputCoverageWeight
    }

    static func wordCost(weight: Int64, isChineseCharacter: Bool = false) -> Double {
        (wordInsertionCost - frequencyWeight * log(Double(max(1, weight)))
            + (isChineseCharacter ? characterInsertionCost : 0)) / log(2.0)
    }

    /// Charge each English dictionary token, shared by lookup and sentence edges.
    static func englishWordCost(weight: Int64) -> Double {
        wordCost(weight: weight) + englishWordInsertionCost / log(2.0)
    }

    static func languageCost(previous: Int, next: Int) -> Double {
        guard previous != 0 else { return initialLanguageCost }
        return -log2(previous == next ? 1 - RankingCalibration.switchProbability : RankingCalibration.switchProbability)
    }

    /// Observe each Chinese syllable independently, including initials and missing syllables.
    /// Canonical umlaut aliases must not change the spelling cost or source boundaries.
    static func chineseSpellingCost(reading: [String], typed: [String]) -> Double {
        reading.enumerated().reduce(0) { result, item in
            let length = ChineseSyllables.canonical(item.element).utf8.count
            let observed = item.offset < typed.count ? ChineseSyllables.canonical(typed[item.offset]).utf8.count : 0
            return result + PinyinSpellingChannel.cost(length: length, typedLength: min(length, observed))
        }
    }

    static func personalCost(codeLength: Int, typedLength: Int, pinned: Bool) -> Double {
        wordCost(weight: personalWeight) - (pinned ? 1 : 0)
            + WordPrefixChannel.cost(fullLength: codeLength, typedLength: typedLength)
    }
}
