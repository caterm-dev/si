import Foundation

/// One global aggregate choice, never a chronological input record.
public struct ApplicationVocabularyEntry: Codable, Equatable, Identifiable, Sendable {
    public let preference: LearnedPreference
    public let count: Int
    /// Explicit nonfirst choices, independent of the total usage count.
    public let correctionCount: Int
    public let baseScore: Double
    public let lexicalTokenCount: Int?
    /// Latest deliberate correction only; accepting the first choice does not refresh it.
    public let lastSelected: Date?

    public var id: String { preference.id }

    public init(preference: LearnedPreference, count: Int, baseScore: Double,
                lexicalTokenCount: Int?, correctionCount: Int = 0, lastSelected: Date? = nil) {
        self.preference = preference
        self.count = count
        self.correctionCount = correctionCount
        self.baseScore = baseScore
        self.lexicalTokenCount = lexicalTokenCount
        self.lastSelected = lastSelected
    }

    private enum CodingKeys: String, CodingKey {
        case preference, count, correctionCount, baseScore, lexicalTokenCount, lastSelected
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        preference = try values.decode(LearnedPreference.self, forKey: .preference)
        count = try values.decode(Int.self, forKey: .count)
        correctionCount = try values.decodeIfPresent(Int.self, forKey: .correctionCount) ?? 0
        baseScore = try values.decode(Double.self, forKey: .baseScore)
        lexicalTokenCount = try values.decodeIfPresent(Int.self, forKey: .lexicalTokenCount)
        lastSelected = try values.decodeIfPresent(Date.self, forKey: .lastSelected)
    }
}
