import Foundation

public struct CandidateEngine: Sendable {
    public static var precedingTextUTF16Limit: Int { RustConversion.precedingTextUTF16Limit }
    public enum PinyinCorrectionMode: UInt8, CaseIterable, Sendable {
        case off, conservative, higherRecall
    }

    var pinyinCorrectionMode: PinyinCorrectionMode = .off
    var rerankingEnabled = false
    private let providers: [any CandidateProvider]?
    private let usesCoverageAdjustedOrder: Bool
    public var punctuationCandidatesEnabled: Bool
    public init(providers: [any CandidateProvider]? = nil, punctuationCandidatesEnabled: Bool = false,
                usesCoverageAdjustedOrder: Bool = true) {
        self.providers = providers
        self.punctuationCandidatesEnabled = punctuationCandidatesEnabled
        self.usesCoverageAdjustedOrder = usesCoverageAdjustedOrder
    }

    public func candidates(for input: String, languages: Set<InputLanguage>,
                           learning: LearningProfile = LearningProfile(), dictionary: UserDictionary = UserDictionary(),
                           now: Date = .now, context: CandidateContext? = nil,
                           includesConfirmationEvidence: Bool = false,
                           applicationMemory: ApplicationMemorySnapshot = .empty,
                           precedingText: String? = nil, precedingTextCache: PrecedingTextCache? = nil) -> [InputCandidate] {
        converted(input, languages: languages, learning: learning, dictionary: dictionary,
                  now: now, context: context, applicationMemory: applicationMemory, preview: false,
                  includesConfirmation: includesConfirmationEvidence, precedingText: precedingText,
                  precedingTextCache: precedingTextCache,
                  rerankingEnabled: rerankingEnabled)
    }


    func previewCandidates(for input: String, languages: Set<InputLanguage>, learning: LearningProfile,
                           dictionary: UserDictionary, now: Date, context: CandidateContext?,
                           applicationMemory: ApplicationMemorySnapshot = .empty,
                           precedingText: String? = nil, precedingTextCache: PrecedingTextCache? = nil) -> [InputCandidate] {
        return converted(input, languages: languages, learning: learning, dictionary: dictionary,
                         now: now, context: context, applicationMemory: applicationMemory, preview: true,
                         precedingText: precedingText, precedingTextCache: precedingTextCache)
    }

    private func converted(_ input: String, languages: Set<InputLanguage>, learning: LearningProfile,
                           dictionary: UserDictionary, now: Date, context: CandidateContext?,
                           applicationMemory: ApplicationMemorySnapshot, preview: Bool,
                           includesConfirmation: Bool = false, precedingText: String?,
                           precedingTextCache: PrecedingTextCache? = nil,
                           rerankingEnabled: Bool = false) -> [InputCandidate] {
        guard !input.isEmpty else { return [] }
        let generated: [InputCandidate]
        if let providers {
            let provided = preview ? [] : providers.filter { $0.requiredLanguages.isSubset(of: languages) }
                .flatMap { $0.candidates(for: input) }
            generated = provided + dictionary.candidates(for: input, languages: languages)
        } else {
            let rust = applicationMemory.sentenceModel?.conversion ?? RustConversion.shared
            generated = rust?.candidates(for: input, languages: languages, preview: preview,
                dictionary: dictionary, includesConfirmation: includesConfirmation, learning: learning, now: now,
                context: context, precedingText: precedingText, precedingTextCache: precedingTextCache,
                correctionMode: pinyinCorrectionMode,
                rerankingEnabled: rerankingEnabled)
                ?? dictionary.candidates(for: input, languages: languages)
        }
        var entries = generated
        if punctuationCandidatesEnabled, let punctuation = PunctuationCandidates.split(input),
           !PunctuationCandidates.hasRecognizedSuffix(punctuation.prefix) {
            let prefixes = punctuation.prefix.isEmpty
                ? [InputCandidate(text: "", language: nil, score: 0)]
                : converted(punctuation.prefix, languages: languages, learning: learning, dictionary: dictionary,
                            now: now, context: context, applicationMemory: applicationMemory, preview: preview,
                            precedingText: precedingText, precedingTextCache: precedingTextCache)
            entries += PunctuationCandidates.candidates(symbol: punctuation.symbol, prefixes: prefixes, languages: languages) {
                learning.rankingScore(for: $0, input: punctuation.prefix, now: now, context: context)
                    + $0.fieldContextAdjustment
            }
        }
        let known = Set(entries.lazy.map(\.id))
        entries += applicationMemory.vocabularyCandidates(for: input, languages: languages, now: now)
            .filter { !known.contains($0.id) }
        let preferredID = applicationMemory.preferredCandidateID(for: input, languages: languages)
        let inputCount = input.count
        let scored = entries.compactMap { candidate -> InputCandidate? in
            // Session spans count Characters; validate before slicing personal-preference input.
            if let consumed = candidate.consumedInputCount, consumed <= 0 || consumed >= inputCount { return nil }
            guard !candidate.isMixed || candidate.language == .simplifiedChinese else { return nil }
            let spelling = candidate.consumedInputCount.map { String(input.prefix($0)) } ?? input
            let statisticalScore = learning.rankingScore(for: candidate, input: spelling, now: now, context: context)
                + candidate.fieldContextAdjustment
            return candidate.withPresentationScore(0, remembered: candidate.id == preferredID,
                                                     statisticalScore: statisticalScore)
        }
        return RustCandidatePresentation.merge(scored + [literalCandidate(for: input)], input: input,
                                               languages: languages, coverageOrder: usesCoverageAdjustedOrder)
    }

    func literalCandidate(for input: String) -> InputCandidate {
        InputCandidate(text: input, language: nil, score: 0,
                       isPunctuation: punctuationCandidatesEnabled && PunctuationCandidates.split(input) != nil)
    }
}
