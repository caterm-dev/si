import Foundation

/// An aggregate choice in one application, not a chronological input record.
public struct ApplicationVocabularyEntry: Codable, Equatable, Identifiable, Sendable {
    public let applicationID: String
    public let preference: LearnedPreference
    public let count: Int
    public let baseScore: Double
    public let lexicalTokenCount: Int?

    public var id: String { "\(applicationID.utf8.count):\(applicationID)\(preference.id)" }

    public init(applicationID: String, preference: LearnedPreference, count: Int,
                baseScore: Double, lexicalTokenCount: Int?) {
        self.applicationID = applicationID
        self.preference = preference
        self.count = count
        self.baseScore = baseScore
        self.lexicalTokenCount = lexicalTokenCount
    }
}
