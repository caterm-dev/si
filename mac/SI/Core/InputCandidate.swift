public struct InputCandidate: Identifiable, Equatable, Sendable {
    public let text: String
    public let language: InputLanguage?
    public let score: Int
    /// Base lexical score for the spelling this candidate actually consumes.
    public let rankingScore: Double
    /// Lexical score with eligible learning and field context, before input coverage.
    public private(set) var statisticalScore: Double?
    /// Presentation score, including field context, eligible learning, coverage and model adjustment.
    public private(set) var presentationScore: Double?
    /// Transient Rust gram adjustment from the preceding field text.
    var fieldContextAdjustment = 0.0
    /// Ephemeral nonpositive sequence-lift adjustment from the local character model.
    var rerankingBonus = 0.0
    /// Exact-spelling correction priority is separate from statistical score units.
    public private(set) var isRememberedChoice = false
    /// Lexical score before learning and the consumed-input coverage reward.
    public var inputScore: Double { rankingScore }
    private var displaySourceBoundaries: [Int] = []
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
    public let isPinyinCorrection: Bool
    public var requiresExplicitSelection: Bool { isPinyinCorrection }
    public let consumedInputCount: Int?
    /// Transient lexical-node count for word-selection presentation, independent of identity and score.
    public private(set) var lexicalTokenCount: Int?
    public let confirmationBoundaries: [ConfirmationBoundary]

    /// Exact source-character cuts for displaying Chinese syllables and English words.
    /// This is presentation metadata, independent of commit alignment evidence.
    public var sourceSegmentBoundaries: [Int] {
        var result = displaySourceBoundaries
        return Array(Set(result)).sorted()
    }

    // Language is part of identity: matching text from two languages remains visible.
    public let id: String
    public var isLiteral: Bool { language == nil }
    public var isPartial: Bool { consumedInputCount != nil }
    public var isLexicalPrefix: Bool { isPartial && lexicalTokenCount == 1 && !hasCompletion && !hasLiteralSegments }
    public var canLearn: Bool { !isLiteral && !isUserPhrase && !hasLiteralSegments && !requiresExplicitSelection && punctuationLanguage == nil }
    public var label: String {
        let languageLabel = punctuationLanguage.map { $0 == .english ? "English Punctuation" : "Chinese Punctuation" }
            ?? (isMixed ? (hasLiteralSegments ? "Chinese + As Typed" : "Chinese + English") : language?.displayName ?? "As Typed")
        let source = isApplicationVocabulary ? "Personal Learning · \(languageLabel)"
            : isPinyinCorrection ? "Spelling correction · \(languageLabel)"
            : isUserPhrase ? "Personal · \(languageLabel)" : languageLabel
        return consumedInputCount.map { "First \($0) characters · \(source)" } ?? source
    }
    public init(text: String, language: InputLanguage?, score: Int, isMixed: Bool = false, isUserPhrase: Bool = false,
                hasLiteralSegments: Bool = false, consumedInputCount: Int? = nil, rankingScore: Double? = nil,
                hasCompletion: Bool = false, tokenLearningBonus: Double = 0, isPreferred: Bool = false,
                lexicalTokenCount: Int? = nil, confirmationBoundaries: [ConfirmationBoundary] = [],
                isApplicationVocabulary: Bool = false,
                punctuationLanguage: InputLanguage? = nil, isPunctuation: Bool = false,
                isPinyinCorrection: Bool = false) {
        self.text = text
        self.language = language
        self.score = score
        self.isPinyinCorrection = isPinyinCorrection
        self.rankingScore = rankingScore.flatMap { $0.isFinite ? $0 : nil } ?? Double(score)
        self.tokenLearningBonus = language != nil && !isUserPhrase && !hasLiteralSegments && !isPinyinCorrection && tokenLearningBonus.isFinite
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
        self.confirmationBoundaries = isPinyinCorrection ? [] : confirmationBoundaries
        let base = "\(isMixed && language != nil ? "zh-Hans+en" : language?.rawValue ?? "literal"):\(text)"
        let punctuated = self.punctuationLanguage.map { "punctuation:\($0.rawValue):\(base)" } ?? base
        let identity = consumedInputCount.map { "prefix\($0):\(punctuated)" } ?? punctuated
        id = identity
    }

    func withPresentationEvidence(lexicalTokenCount: Int?, chineseSentence: Bool) -> Self {
        var result = self
        result.lexicalTokenCount = lexicalTokenCount
        result.isChineseSentence = chineseSentence
        return result
    }

    func withChineseSentenceOrigin() -> Self {
        var result = self
        result.isChineseSentence = language == .simplifiedChinese && !isMixed && !isPartial
            && !isUserPhrase && !hasLiteralSegments && !requiresExplicitSelection && punctuationLanguage == nil
        return result
    }

    func withPresentationScore(_ score: Double, remembered: Bool, statisticalScore: Double? = nil) -> Self {
        var result = self
        result.presentationScore = score
        result.statisticalScore = statisticalScore
        result.isRememberedChoice = remembered
        return result
    }

    func withDisplaySourceBoundaries(_ boundaries: [Int]) -> Self {
        var result = self
        result.displaySourceBoundaries = boundaries
        return result
    }

    func hasSameCommitValue(as other: Self) -> Bool {
        var left = self
        var right = other
        // Transient decoder evidence does not change the committed value.
        left.displaySourceBoundaries = []
        right.displaySourceBoundaries = []
        left.isChineseSentence = false
        right.isChineseSentence = false
        left.presentationScore = nil
        right.presentationScore = nil
        left.statisticalScore = nil
        right.statisticalScore = nil
        left.rerankingBonus = 0
        right.rerankingBonus = 0
        left.isRememberedChoice = false
        right.isRememberedChoice = false
        return left == right
    }
}
