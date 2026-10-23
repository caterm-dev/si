public struct InputCandidate: Identifiable, Equatable, Sendable {
    public let text: String
    public let language: InputLanguage?
    public let score: Int
    /// Base lexical score for the spelling this candidate actually consumes.
    public let rankingScore: Double
    /// Request-local score for handling the exact unconsumed spelling after a prefix confirmation.
    /// Kept separate from the word score so it cannot be persisted as a learned word frequency.
    public private(set) var remainingInputScore = 0.0
    /// Full-input comparison score before preferences; complete candidates keep their base score.
    public var inputScore: Double { rankingScore + remainingInputScore }
    var wordContext: CandidateWordContext?
    var sourceTrace: CandidateSourceTrace?
    /// Runtime provenance for Chinese sentence placement; lexical matches keep their own positions.
    private(set) var isChineseSentence = false
    /// Ephemeral length-weighted token preference; shares the frequency cap with whole-input learning.
    let tokenLearningBonus: Double
    public let isMixed: Bool
    public let isUserPhrase: Bool
    public let isApplicationVocabulary: Bool
    public let isHistory: Bool
    /// Original uncommitted source spelling of a history completion; never a document range.
    public let historyInput: String?
    /// Language of an explicitly selectable punctuation variant, independent of its word prefix.
    public let punctuationLanguage: InputLanguage?
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
    public var isLiteral: Bool { language == nil && !isHistory }
    public var isPartial: Bool { consumedInputCount != nil }
    public var isLexicalPrefix: Bool { isPartial && lexicalTokenCount == 1 && !hasCompletion && !hasLiteralSegments }
    public var canLearn: Bool { !isLiteral && !isUserPhrase && !isHistory && !hasLiteralSegments && punctuationLanguage == nil }
    public var label: String {
        let languageLabel = punctuationLanguage.map { $0 == .english ? "English Punctuation" : "Chinese Punctuation" }
            ?? (isMixed ? (hasLiteralSegments ? "Chinese + As Typed" : "Chinese + English") : language?.displayName ?? "As Typed")
        let source = isHistory ? "App History" : isApplicationVocabulary ? "App Vocabulary · \(languageLabel)"
            : isUserPhrase ? "Personal · \(languageLabel)" : languageLabel
        return consumedInputCount.map { "First \($0) characters · \(source)" } ?? source
    }
    public var appendsSpaceOnAcceptance: Bool {
        !isHistory && punctuationLanguage == nil && PunctuationCandidates.split(text) == nil
            && (isLiteral || language == .english || (isMixed && text.last?.isASCII == true))
    }

    public init(text: String, language: InputLanguage?, score: Int, isMixed: Bool = false, isUserPhrase: Bool = false,
                hasLiteralSegments: Bool = false, consumedInputCount: Int? = nil, rankingScore: Double? = nil,
                hasCompletion: Bool = false, tokenLearningBonus: Double = 0, isPreferred: Bool = false,
                lexicalTokenCount: Int? = nil, confirmationBoundaries: [ConfirmationBoundary] = [],
                isApplicationVocabulary: Bool = false, isHistory: Bool = false, historyInput: String? = nil,
                punctuationLanguage: InputLanguage? = nil) {
        self.text = text
        self.language = language
        self.score = score
        self.rankingScore = rankingScore.flatMap { $0.isFinite ? $0 : nil } ?? Double(score)
        self.tokenLearningBonus = language != nil && !isUserPhrase && !hasLiteralSegments && tokenLearningBonus.isFinite
            ? min(32, max(0, tokenLearningBonus)) : 0
        self.isMixed = isMixed && language != nil
        self.isUserPhrase = isUserPhrase && language != nil
        self.isApplicationVocabulary = isApplicationVocabulary && language != nil && !isHistory
        self.isHistory = isHistory
        self.historyInput = isHistory ? historyInput : nil
        self.punctuationLanguage = language == nil ? nil : punctuationLanguage
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
        id = isHistory ? "history:\(identity)" : identity
    }

    /// A stronger composed derivation must not erase evidence that the same output is one lexical unit.
    mutating func retainLexicalEvidence(from other: InputCandidate) {
        if other.lexicalTokenCount == 1 { lexicalTokenCount = 1 }
        isChineseSentence = isChineseSentence && other.isChineseSentence
    }

    func withChineseSentenceOrigin() -> Self {
        var result = self
        result.isChineseSentence = language == .simplifiedChinese && !isMixed && !isPartial
            && !isUserPhrase && !hasLiteralSegments && !isHistory && punctuationLanguage == nil
        return result
    }

    mutating func accountForRemainingInput(score: Double) {
        remainingInputScore = isPartial && score.isFinite ? score : 0
    }

    func withWordContext(_ context: CandidateWordContext) -> Self {
        var result = self
        result.wordContext = context
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
        // Request-local lookahead must not invalidate an otherwise identical decoder candidate.
        left.remainingInputScore = 0
        right.remainingInputScore = 0
        left.wordContext = nil
        right.wordContext = nil
        left.sourceTrace = nil
        right.sourceTrace = nil
        left.isChineseSentence = false
        right.isChineseSentence = false
        return left == right
    }
}
