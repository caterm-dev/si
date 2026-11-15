import Foundation

public struct CandidateEngine: Sendable {
    private let providers: [any CandidateProvider]?
    public var punctuationCandidatesEnabled: Bool
    public init(providers: [any CandidateProvider]? = nil, punctuationCandidatesEnabled: Bool = false) {
        self.providers = providers
        self.punctuationCandidatesEnabled = punctuationCandidatesEnabled
    }

    public func candidates(for input: String, languages: Set<InputLanguage>,
                           learning: LearningProfile = LearningProfile(), dictionary: UserDictionary = UserDictionary(),
                           now: Date = .now, context: CandidateContext? = nil,
                           includesConfirmationEvidence: Bool = false,
                           applicationMemory: ApplicationMemorySnapshot = .empty,
                           precedingText: String = "") -> [InputCandidate] {
        return converted(input, languages: languages, learning: learning, dictionary: dictionary,
                         now: now, context: context, applicationMemory: applicationMemory, preview: false,
                         includesConfirmation: includesConfirmationEvidence, precedingText: precedingText)
    }


    func previewCandidates(for input: String, languages: Set<InputLanguage>, learning: LearningProfile,
                           dictionary: UserDictionary, now: Date, context: CandidateContext?,
                           applicationMemory: ApplicationMemorySnapshot = .empty,
                           precedingText: String = "") -> [InputCandidate] {
        return converted(input, languages: languages, learning: learning, dictionary: dictionary,
                         now: now, context: context, applicationMemory: applicationMemory, preview: true,
                         precedingText: precedingText)
    }

    private func converted(_ input: String, languages: Set<InputLanguage>, learning: LearningProfile,
                           dictionary: UserDictionary, now: Date, context: CandidateContext?,
                           applicationMemory: ApplicationMemorySnapshot, preview: Bool,
                           includesConfirmation: Bool = false, precedingText: String) -> [InputCandidate] {
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
                context: context, precedingText: precedingText)
                ?? dictionary.candidates(for: input, languages: languages)
        }
        var entries = generated
        if punctuationCandidatesEnabled, let punctuation = PunctuationCandidates.split(input),
           !PunctuationCandidates.hasRecognizedSuffix(punctuation.prefix) {
            let prefixes = punctuation.prefix.isEmpty
                ? [InputCandidate(text: "", language: nil, score: 0)]
                : converted(punctuation.prefix, languages: languages, learning: learning, dictionary: dictionary,
                            now: now, context: context, applicationMemory: applicationMemory, preview: preview,
                            precedingText: precedingText)
            entries += PunctuationCandidates.candidates(symbol: punctuation.symbol, prefixes: prefixes, languages: languages) {
                learning.rankingScore(for: $0, input: punctuation.prefix, now: now, context: context)
                    + $0.fieldContextAdjustment
            }
        }
        let known = Set(entries.map(\.id))
        entries += applicationMemory.vocabularyCandidates(for: input, languages: languages, now: now)
            .filter { !known.contains($0.id) }
        let preferredID = applicationMemory.preferredCandidateID(for: input, languages: languages)
        let inputCount = input.count
        var best: [String: InputCandidate] = [:]
        for candidate in entries {
            guard let language = candidate.language, languages.contains(language), !candidate.text.isEmpty,
                  !candidate.isMixed || (language == .simplifiedChinese && languages.contains(.english)) else { continue }
            if let consumed = candidate.consumedInputCount, consumed <= 0 || consumed >= inputCount { continue }
            let spelling = candidate.consumedInputCount.map { String(input.prefix($0)) } ?? input
            let score = learning.rankingScore(for: candidate, input: spelling, now: now, context: context)
                + candidate.fieldContextAdjustment
                + CandidateScoring.inputCoverageBonus(for: candidate, spelling: spelling)
            let remembered = candidate.canLearn && !candidate.isPartial && candidate.id == preferredID
            var ranked = candidate.withPresentationScore(score, remembered: remembered)
            if let previous = best[ranked.id] {
                if precedes(previous, ranked, inputCount: inputCount) {
                    best[ranked.id]?.retainLexicalEvidence(from: ranked)
                    continue
                }
                ranked.retainLexicalEvidence(from: previous)
            }
            best[ranked.id] = ranked
        }
        return best.values.sorted { precedes($0, $1, inputCount: inputCount) } + [literalCandidate(for: input)]
    }

    private func precedes(_ left: InputCandidate, _ right: InputCandidate, inputCount: Int) -> Bool {
        if left.isPreferred != right.isPreferred { return left.isPreferred }
        if left.isRememberedChoice != right.isRememberedChoice { return left.isRememberedChoice }
        let leftConsumed = left.consumedInputCount ?? inputCount
        let rightConsumed = right.consumedInputCount ?? inputCount
        if leftConsumed != rightConsumed { return leftConsumed > rightConsumed }
        let leftScore = left.presentationScore ?? left.rankingScore
        let rightScore = right.presentationScore ?? right.rankingScore
        if leftScore != rightScore { return leftScore > rightScore }
        return left.id < right.id
    }

    func literalCandidate(for input: String) -> InputCandidate {
        InputCandidate(text: input, language: nil, score: 0,
                       isPunctuation: punctuationCandidatesEnabled && PunctuationCandidates.split(input) != nil)
    }
}
