public struct InputCandidate: Identifiable, Equatable, Sendable {
    public let text: String
    public let language: InputLanguage?
    public let score: Int
    /// Base lexical score for the spelling this candidate actually consumes.
    public let rankingScore: Double
    /// Final engine score, including eligible learning and consumed-spelling coverage.
    public private(set) var presentationScore: Double?
    /// Exact-spelling correction priority is separate from statistical score units.
    public private(set) var isRememberedChoice = false
    /// Lexical score before learning and the consumed-input coverage reward.
    public var inputScore: Double { rankingScore }
    var languageBoundary: CandidateLanguageBoundary?
    var sourceTrace: CandidateSourceTrace?
    /// Runtime provenance for generated Chinese sentence alternatives.
    private(set) var isChineseSentence = false
    /// Ephemeral length-weighted token preference; shares the frequency cap with whole-input learning.
    let tokenLearningBonus: Double
    public let isMixed: Bool
    public let isUserPhrase: Bool
    public let isApplicationVocabulary: Bool
    /// Language of an explicitly selectable punctuation variant, independent of its word prefix.
    public let punctuationLanguage: InputLanguage?
    /// Explicit punctuation presentation/acceptance metadata, including its exact literal fallback.
    public let isPunctuation: Bool
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
    public var canLearn: Bool { !isLiteral && !isUserPhrase && !hasLiteralSegments && punctuationLanguage == nil }
    public var label: String {
        let languageLabel = punctuationLanguage.map { $0 == .english ? "English Punctuation" : "Chinese Punctuation" }
            ?? (isMixed ? (hasLiteralSegments ? "Chinese + As Typed" : "Chinese + English") : language?.displayName ?? "As Typed")
        let source = isApplicationVocabulary ? "Personal Learning · \(languageLabel)"
            : isUserPhrase ? "Personal · \(languageLabel)" : languageLabel
        return consumedInputCount.map { "First \($0) characters · \(source)" } ?? source
    }
    public var appendsSpaceOnAcceptance: Bool {
        !isPunctuation
            && (isLiteral || language == .english || (isMixed && text.last?.isASCII == true))
    }

    public init(text: String, language: InputLanguage?, score: Int, isMixed: Bool = false, isUserPhrase: Bool = false,
                hasLiteralSegments: Bool = false, consumedInputCount: Int? = nil, rankingScore: Double? = nil,
                hasCompletion: Bool = false, tokenLearningBonus: Double = 0, isPreferred: Bool = false,
                lexicalTokenCount: Int? = nil, confirmationBoundaries: [ConfirmationBoundary] = [],
                isApplicationVocabulary: Bool = false,
                punctuationLanguage: InputLanguage? = nil, isPunctuation: Bool = false) {
        self.text = text
        self.language = language
        self.score = score
        self.rankingScore = rankingScore.flatMap { $0.isFinite ? $0 : nil } ?? Double(score)
        self.tokenLearningBonus = language != nil && !isUserPhrase && !hasLiteralSegments && tokenLearningBonus.isFinite
            ? min(32, max(0, tokenLearningBonus)) : 0
        self.isMixed = isMixed && language != nil
        self.isUserPhrase = isUserPhrase && language != nil
        self.isApplicationVocabulary = isApplicationVocabulary && language != nil
        self.punctuationLanguage = language == nil ? nil : punctuationLanguage
        self.isPunctuation = self.punctuationLanguage != nil || (language == nil && isPunctuation)
        self.isPreferred = isPreferred && self.isUserPhrase && consumedInputCount == nil && !hasCompletion
        self.hasLiteralSegments = hasLiteralSegments
        self.hasCompletion = hasCompletion
        self.consumedInputCount = consumedInputCount
        self.lexicalTokenCount = language != nil && !hasLiteralSegments
            ? lexicalTokenCount.flatMap { $0 > 0 ? $0 : nil } : nil
        self.confirmationBoundaries = confirmationBoundaries
        let base = "\(isMixed && language != nil ? "zh-Hans+en" : language?.rawValue ?? "literal"):\(text)"
        let punctuated = self.punctuationLanguage.map { "punctuation:\($0.rawValue):\(base)" } ?? base
        let identity = consumedInputCount.map { "prefix\($0):\(punctuated)" } ?? punctuated
        id = identity
    }

    /// A stronger composed derivation must not erase evidence that the same output is one lexical unit.
    mutating func retainLexicalEvidence(from other: InputCandidate) {
        if other.lexicalTokenCount == 1 { lexicalTokenCount = 1 }
        isChineseSentence = isChineseSentence && other.isChineseSentence
    }

    func withChineseSentenceOrigin() -> Self {
        var result = self
        result.isChineseSentence = language == .simplifiedChinese && !isMixed && !isPartial
            && !isUserPhrase && !hasLiteralSegments && punctuationLanguage == nil
        return result
    }

    func withPresentationScore(_ score: Double, remembered: Bool) -> Self {
        var result = self
        result.presentationScore = score
        result.isRememberedChoice = remembered
        return result
    }

    func withLanguageBoundary(_ context: CandidateLanguageBoundary) -> Self {
        var result = self
        result.languageBoundary = context
        return result
    }

    func withSourceTrace(_ trace: CandidateSourceTrace?) -> Self {
        var result = self
        result.sourceTrace = trace
        return result
    }

    func hasSameCommitValue(as other: Self) -> Bool {
        var left = self
        var right = other
        // Transient decoder evidence does not change the committed value.
        left.languageBoundary = nil
        right.languageBoundary = nil
        left.sourceTrace = nil
        right.sourceTrace = nil
        left.isChineseSentence = false
        right.isChineseSentence = false
        left.presentationScore = nil
        right.presentationScore = nil
        left.isRememberedChoice = false
        right.isRememberedChoice = false
        return left == right
    }
}
