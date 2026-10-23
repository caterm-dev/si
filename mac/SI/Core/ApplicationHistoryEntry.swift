import Foundation

/// A deduplicated, Return-delimited input unit, scoped to its client application.
public struct ApplicationHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    public let applicationID: String
    public let input: String
    public let text: String
    public let languages: Set<InputLanguage>
    public let count: Int
    public let lastUsed: Date

    public var id: String {
        // Byte identity preserves casing, normalization and explicit source separators.
        "\(applicationID.utf8.count):\(applicationID)\(Data(input.utf8).base64EncodedString()):\(Data(text.utf8).base64EncodedString()):"
            + languages.map(\.rawValue).sorted().joined(separator: ",")
    }

    public init(applicationID: String, input: String, text: String, languages: Set<InputLanguage>,
                count: Int, lastUsed: Date) {
        self.applicationID = applicationID
        self.input = input
        self.text = text
        self.languages = languages
        self.count = count
        self.lastUsed = lastUsed
    }
}
