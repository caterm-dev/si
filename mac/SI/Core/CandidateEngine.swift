import Foundation

public struct CandidateEngine: Sendable {
    private let providers: [any CandidateProvider]?
    public var punctuationCandidatesEnabled: Bool
    public init(providers: [any CandidateProvider]? = nil, punctuationCandidatesEnabled: Bool = false) {
        self.providers = providers
        self.punctuationCandidatesEnabled = punctuationCandidatesEnabled
        // Creating a deferred client session must not load dictionaries on the main actor.
        // The shared immutable resources initialize when its worker first generates candidates.
    }

    public func candidates(for input: String, languages: Set<InputLanguage>,
                           learning: LearningProfile = LearningProfile(), dictionary: UserDictionary = UserDictionary(),
                           now: Date = .now, context: CandidateContext? = nil,
                           includesConfirmationEvidence: Bool = false,
                           applicationMemory: ApplicationMemorySnapshot = .empty) -> [InputCandidate] {
        guard !input.isEmpty else { return [] }
        var generated: [InputCandidate]
        if let providers {
            generated = providers.filter { $0.requiredLanguages.isSubset(of: languages) }.flatMap { $0.candidates(for: input) }
                + dictionary.candidates(for: input, languages: languages)
        } else {
            generated = (languages.contains(.english) ? EnglishCandidateProvider().candidates(for: input) : [])
                + PinyinDecoder.standard.compositionCandidates(for: input, languages: languages, dictionary: dictionary,
                                                               learning: learning, now: now, context: context,
                                                               includesConfirmationEvidence: includesConfirmationEvidence)
        }
        generated += punctuationCandidates(for: input, languages: languages, learning: learning, dictionary: dictionary,
                                            now: now, context: context, applicationMemory: applicationMemory, preview: false)
        let identities = Set(generated.map(\.id))
        let saved = applicationMemory.vocabularyCandidates(for: input, languages: languages, now: now)
            .filter { !identities.contains($0.id) }
        let merged = merge(generated + saved,
                           input: input, languages: languages, learning: learning,
                           now: now, context: context)
        return merged
    }

    /// Provisional hints share the normal lookup/lattice/merge, with smaller lexical budgets.
    /// Custom providers have no bounded-preview contract, so they run only in the final search.
    func previewCandidates(for input: String, languages: Set<InputLanguage>, learning: LearningProfile,
                           dictionary: UserDictionary, now: Date, context: CandidateContext?,
                           applicationMemory: ApplicationMemorySnapshot = .empty) -> [InputCandidate] {
        guard !input.isEmpty else { return [] }
        guard providers == nil else {
            return punctuationCandidates(for: input, languages: languages, learning: learning, dictionary: dictionary,
                                         now: now, context: context, applicationMemory: applicationMemory, preview: true)
                + [literalCandidate(for: input)]
        }
        var generated: [InputCandidate] = []
        if languages.contains(.english) {
            let key = input.lowercased()
            let style = EnglishLexicon.CaseStyle(input: input)
            generated = EnglishLexicon.previewMatches(for: key).map {
                InputCandidate(text: $0.text(for: style), language: .english,
                               score: Int(-$0.cost(typedLength: key.utf8.count) * CandidateScoring.pointsPerBit),
                               rankingScore: -$0.cost(typedLength: key.utf8.count) * CandidateScoring.pointsPerBit,
                               hasCompletion: $0.text.lowercased() != key, lexicalTokenCount: 1)
                    .withLanguageBoundary(.english())
            }
        }
        generated += PinyinDecoder.standard.compositionCandidates(for: input, languages: languages,
            dictionary: dictionary, learning: learning, now: now, context: context, preview: true)
        generated += punctuationCandidates(for: input, languages: languages, learning: learning, dictionary: dictionary,
                                            now: now, context: context, applicationMemory: applicationMemory, preview: true)
        let identities = Set(generated.map(\.id))
        let saved = applicationMemory.vocabularyCandidates(for: input, languages: languages, now: now)
            .filter { !identities.contains($0.id) }
        let merged = merge(generated + saved,
                           input: input, languages: languages, learning: learning,
                           now: now, context: context)
        return merged
    }

    private func punctuationCandidates(for input: String, languages: Set<InputLanguage>, learning: LearningProfile,
                                       dictionary: UserDictionary, now: Date, context: CandidateContext?,
                                       applicationMemory: ApplicationMemorySnapshot, preview: Bool) -> [InputCandidate] {
        guard punctuationCandidatesEnabled, let punctuation = PunctuationCandidates.split(input),
              !PunctuationCandidates.hasRecognizedSuffix(punctuation.prefix) else { return [] }
        let prefixes: [InputCandidate]
        if punctuation.prefix.isEmpty {
            prefixes = [InputCandidate(text: "", language: nil, score: 0)]
        } else if preview {
            prefixes = previewCandidates(for: punctuation.prefix, languages: languages, learning: learning,
                                         dictionary: dictionary, now: now, context: context, applicationMemory: applicationMemory)
        } else {
            prefixes = candidates(for: punctuation.prefix, languages: languages, learning: learning, dictionary: dictionary,
                                  now: now, context: context, applicationMemory: applicationMemory)
        }
        return PunctuationCandidates.candidates(symbol: punctuation.symbol, prefixes: prefixes, languages: languages) {
            learning.rankingScore(for: $0, input: punctuation.prefix, now: now, context: context)
        }
    }

    private func merge(_ generated: [InputCandidate], input: String, languages: Set<InputLanguage>,
                       learning: LearningProfile, now: Date,
                       context: CandidateContext?) -> [InputCandidate] {
        // Personal entries may share text with a built-in candidate. Keep the stronger derivation.
        var best: [String: (candidate: InputCandidate, score: Double)] = [:]
        best.reserveCapacity(generated.count)
        for candidate in generated {
            var candidate = candidate
            guard let language = candidate.language, languages.contains(language), !candidate.text.isEmpty else { continue }
            if candidate.isMixed && (language != .simplifiedChinese || !languages.contains(.english)) { continue }
            if let count = candidate.consumedInputCount, count <= 0 || count >= input.count { continue }
            let spelling = candidate.consumedInputCount.map { String(input.prefix($0)) } ?? input
            let score = learning.rankingScore(for: candidate, input: spelling, now: now, context: context)
                + CandidateScoring.inputCoverageBonus(for: candidate, spelling: spelling)
            if let previous = best[candidate.id],
               (previous.candidate.isPreferred && !candidate.isPreferred)
                || (previous.candidate.isPreferred == candidate.isPreferred
                    && (previous.score > score || (previous.score == score && !candidate.isUserPhrase))) {
                best[candidate.id]?.candidate.retainLexicalEvidence(from: candidate)
                continue
            }
            if let previous = best[candidate.id] { candidate.retainLexicalEvidence(from: previous.candidate) }
            best[candidate.id] = (candidate, score)
        }
        let merged = best.values
            .sorted {
                // Shared lexical/preferences score plus reward for actually matched input.
                if $0.candidate.isPreferred != $1.candidate.isPreferred { return $0.candidate.isPreferred }
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.candidate.id < $1.candidate.id
            }
            .map(\.candidate)
        // Never drop an enabled language's candidates because another language matches.
        // Literal input stays available even with all language providers disabled.
        return merged + [literalCandidate(for: input)]
    }

    func literalCandidate(for input: String) -> InputCandidate {
        InputCandidate(text: input, language: nil, score: 0,
                       isPunctuation: punctuationCandidatesEnabled && PunctuationCandidates.split(input) != nil)
    }

}
