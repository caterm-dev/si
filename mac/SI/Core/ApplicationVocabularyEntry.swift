import Foundation

/// An aggregate choice in one application, not a chronological input record.
public struct ApplicationVocabularyEntry: Codable, Equatable, Identifiable, Sendable {
    public let applicationID: String
    public let preference: LearnedPreference
    public let count: Int
    /// Explicit nonfirst choices, independent of the total usage count.
    public let correctionCount: Int
    public let baseScore: Double
    public let lexicalTokenCount: Int?

    public var id: String { "\(applicationID.utf8.count):\(applicationID)\(preference.id)" }

    public init(applicationID: String, preference: LearnedPreference, count: Int,
                baseScore: Double, lexicalTokenCount: Int?, correctionCount: Int = 0) {
        self.applicationID = applicationID
        self.preference = preference
        self.count = count
        self.correctionCount = correctionCount
        self.baseScore = baseScore
        self.lexicalTokenCount = lexicalTokenCount
    }

    private enum CodingKeys: String, CodingKey {
        case applicationID, preference, count, correctionCount, baseScore, lexicalTokenCount
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        applicationID = try values.decode(String.self, forKey: .applicationID)
        preference = try values.decode(LearnedPreference.self, forKey: .preference)
        count = try values.decode(Int.self, forKey: .count)
        correctionCount = try values.decodeIfPresent(Int.self, forKey: .correctionCount) ?? 0
        baseScore = try values.decode(Double.self, forKey: .baseScore)
        lexicalTokenCount = try values.decodeIfPresent(Int.self, forKey: .lexicalTokenCount)
    }
}
