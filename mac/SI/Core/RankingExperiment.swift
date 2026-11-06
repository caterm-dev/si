import Foundation

/// Immutable experimental ranking settings captured with a candidate request.
public struct RankingExperiment: Sendable, Equatable {
    public static let defaultEnglishWordInsertionBits = 23 / log(2.0)

    public var model: KenLMModel?
    public var languageModelWeight: Double
    public var englishLanguageModelWeight: Double
    public var frequencyWeight: Double
    public var wordInsertionBits: Double
    public var englishWordInsertionBits: Double
    public var fullCoverageFirst: Bool

    public init(model: KenLMModel? = nil, languageModelWeight: Double = 0,
                englishLanguageModelWeight: Double = 0, frequencyWeight: Double = 1,
                wordInsertionBits: Double = 20 / log(2.0),
                englishWordInsertionBits: Double = RankingExperiment.defaultEnglishWordInsertionBits,
                fullCoverageFirst: Bool = false) {
        self.model = model
        self.languageModelWeight = languageModelWeight
        self.englishLanguageModelWeight = englishLanguageModelWeight
        self.frequencyWeight = frequencyWeight
        self.wordInsertionBits = wordInsertionBits
        self.englishWordInsertionBits = englishWordInsertionBits
        self.fullCoverageFirst = fullCoverageFirst
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model && lhs.languageModelWeight == rhs.languageModelWeight
            && lhs.englishLanguageModelWeight == rhs.englishLanguageModelWeight
            && lhs.frequencyWeight == rhs.frequencyWeight && lhs.wordInsertionBits == rhs.wordInsertionBits
            && lhs.englishWordInsertionBits == rhs.englishWordInsertionBits
            && lhs.fullCoverageFirst == rhs.fullCoverageFirst
    }

    func coverageOrder(_ lhs: InputCandidate, _ rhs: InputCandidate) -> Bool? {
        guard fullCoverageFirst else { return nil }
        if lhs.isPartial != rhs.isPartial { return !lhs.isPartial }
        if let a = lhs.consumedInputCount, let b = rhs.consumedInputCount, a != b {
            return a > b
        }
        return nil
    }

    var isActive: Bool {
        model != nil && languageModelWeight.isFinite && englishLanguageModelWeight.isFinite
            && frequencyWeight.isFinite && wordInsertionBits.isFinite
            && (languageModelWeight != 0 || englishLanguageModelWeight != 0)
    }

    var adjustsEnglishInsertion: Bool {
        englishWordInsertionBits.isFinite && englishWordInsertionBits != Self.defaultEnglishWordInsertionBits
    }
}

struct RankingToken: Equatable, Sendable {
    let text: String
    let language: InputLanguage
    let weight: Int64

    var frequencyBits: Double { 1.05 * log2(Double(max(weight, 1))) }
}

struct KenLMScorer {
    let model: KenLMModel
    private var indices: [Data: (index: UInt32, isOOV: Bool)] = [:]

    init(model: KenLMModel) { self.model = model }

    mutating func score(_ tokens: [RankingToken], language: InputLanguage,
                        context: [String] = []) -> (bits: Double, oovs: Int, count: Int)? {
        var state = model.beginSentence()
        for text in context.suffix(3) {
            guard let word = lookup(text), let step = model.advance(state, wordIndex: word.index) else { return nil }
            state = step.state
        }
        var bits = 0.0
        var oovs = 0
        var count = 0
        for token in tokens {
            guard token.language == language else {
                // A language boundary starts a new contiguous LM segment.
                state = model.beginSentence()
                continue
            }
            let text = language == .english ? token.text.lowercased() : token.text
            guard let word = lookup(text), let step = model.advance(state, wordIndex: word.index) else { return nil }
            bits += step.log10 * log2(10.0)
            oovs += word.isOOV ? 1 : 0
            count += 1
            state = step.state
        }
        return count == 0 ? nil : (bits, oovs, count)
    }

    private mutating func lookup(_ text: String) -> (index: UInt32, isOOV: Bool)? {
        let key = Data(text.utf8)
        if let existing = indices[key] { return existing }
        guard let result = model.wordIndex(text) else { return nil }
        if indices.count < 1024 { indices[key] = result }
        return result
    }
}
