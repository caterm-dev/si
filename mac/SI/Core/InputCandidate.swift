public struct InputCandidate: Identifiable, Equatable, Sendable {
    public let text: String
    public let language: InputLanguage?
    public let score: Int

    // Language is part of identity: matching text from two languages remains visible.
    public var id: String { "\(language?.rawValue ?? "literal"):\(text)" }
    public var isLiteral: Bool { language == nil }
    public var label: String { language?.displayName ?? "As Typed" }

    public init(text: String, language: InputLanguage?, score: Int) {
        self.text = text
        self.language = language
        self.score = score
    }
}
