import Foundation

/// Shared heuristic costs in bits, using the dictionaries' fixed relative-frequency unit.
/// These scores are comparable across decoders; they are not calibrated probabilities.
enum CandidateScoring {
    static let pointsPerBit = 1.0
    static let terminalCost = 0.0
    static let initialLanguageCost = 1.0
    static let personalWeight: Int64 = 10_000
    private static let wordInsertionCost = 20.0
    private static let characterInsertionCost = 2.0

    static func wordCost(weight: Int64, isChineseCharacter: Bool = false) -> Double {
        (wordInsertionCost - log(Double(max(1, weight)))
            + (isChineseCharacter ? characterInsertionCost : 0)) / log(2.0)
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
