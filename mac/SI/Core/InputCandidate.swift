public struct InputCandidate: Identifiable, Equatable, Sendable {
    public let text: String
    public let language: InputLanguage?
    public let score: Int
    public let rankingScore: Double
    /// Ephemeral length-weighted token preference; shares the frequency cap with whole-input learning.
    let tokenLearningBonus: Double
    public let isMixed: Bool
    public let isUserPhrase: Bool
    /// Explicit preferred-full-code policy, separate from statistical score units.
    public let isPreferred: Bool
    public let hasLiteralSegments: Bool
    public let hasCompletion: Bool
    public let consumedInputCount: Int?
    /// Transient lexical-node count for word-selection presentation, independent of identity and score.
    public private(set) var lexicalTokenCount: Int?
    public let confirmationBoundaries: [ConfirmationBoundary]

    // Language is part of identity: matching text from two languages remains visible.
    public let id: String
    public var isLiteral: Bool { language == nil }
    public var isPartial: Bool { consumedInputCount != nil }
    public var isLexicalPrefix: Bool { isPartial && lexicalTokenCount == 1 && !hasCompletion && !hasLiteralSegments }
    public var canLearn: Bool { !isLiteral && !isUserPhrase && !hasLiteralSegments }
    public var label: String {
        let languageLabel = isMixed ? (hasLiteralSegments ? "Chinese + As Typed" : "Chinese + English") : language?.displayName ?? "As Typed"
        let source = isUserPhrase ? "Personal · \(languageLabel)" : languageLabel
        return consumedInputCount.map { "First \($0) characters · \(source)" } ?? source
    }
    public var appendsSpaceOnAcceptance: Bool {
        isLiteral || language == .english || (isMixed && text.last?.isASCII == true)
    }

    public init(text: String, language: InputLanguage?, score: Int, isMixed: Bool = false, isUserPhrase: Bool = false,
                hasLiteralSegments: Bool = false, consumedInputCount: Int? = nil, rankingScore: Double? = nil,
                hasCompletion: Bool = false, tokenLearningBonus: Double = 0, isPreferred: Bool = false,
                lexicalTokenCount: Int? = nil, confirmationBoundaries: [ConfirmationBoundary] = []) {
        self.text = text
        self.language = language
        self.score = score
        self.rankingScore = rankingScore.flatMap { $0.isFinite ? $0 : nil } ?? Double(score)
        self.tokenLearningBonus = language != nil && !isUserPhrase && !hasLiteralSegments && tokenLearningBonus.isFinite
            ? min(32, max(0, tokenLearningBonus)) : 0
        self.isMixed = isMixed && language != nil
        self.isUserPhrase = isUserPhrase && language != nil
        self.isPreferred = isPreferred && self.isUserPhrase && consumedInputCount == nil && !hasCompletion
        self.hasLiteralSegments = hasLiteralSegments
        self.hasCompletion = hasCompletion
        self.consumedInputCount = consumedInputCount
        self.lexicalTokenCount = language != nil && !hasLiteralSegments
            ? lexicalTokenCount.flatMap { $0 > 0 ? $0 : nil } : nil
        self.confirmationBoundaries = confirmationBoundaries
        let base = "\(isMixed && language != nil ? "zh-Hans+en" : language?.rawValue ?? "literal"):\(text)"
        id = consumedInputCount.map { "prefix\($0):\(base)" } ?? base
    }

    /// A stronger composed derivation must not erase evidence that the same output is one lexical unit.
    mutating func retainLexicalEvidence(from other: InputCandidate) {
        if other.lexicalTokenCount == 1 { lexicalTokenCount = 1 }
    }
}
