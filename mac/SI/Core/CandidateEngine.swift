import Foundation

public struct CandidateEngine: Sendable {
    private let providers: [any CandidateProvider]?

    public init(providers: [any CandidateProvider]? = nil) {
        self.providers = providers
        if providers == nil {
            EnglishLexicon.prepare()
            _ = PinyinDecoder.standard
        }
    }

    public func candidates(for input: String, languages: Set<InputLanguage>,
                           learning: LearningProfile = LearningProfile(), dictionary: UserDictionary = UserDictionary(),
                           now: Date = .now, context: CandidateContext? = nil) -> [InputCandidate] {
        guard !input.isEmpty else { return [] }
        let generated: [InputCandidate]
        if let providers {
            generated = providers.filter { $0.requiredLanguages.isSubset(of: languages) }.flatMap { $0.candidates(for: input) }
                + dictionary.candidates(for: input, languages: languages)
        } else {
            generated = (languages.contains(.english) ? EnglishCandidateProvider().candidates(for: input) : [])
                + PinyinDecoder.standard.compositionCandidates(for: input, languages: languages, dictionary: dictionary,
                                                               learning: learning, now: now, context: context)
        }
        // Personal entries may share text with a built-in candidate. Keep the stronger derivation.
        var best: [String: (candidate: InputCandidate, score: Double)] = [:]
        best.reserveCapacity(generated.count)
        for candidate in generated {
            guard let language = candidate.language, languages.contains(language), !candidate.text.isEmpty else { continue }
            if candidate.isMixed && (language != .simplifiedChinese || !languages.contains(.english)) { continue }
            if let count = candidate.consumedInputCount, count <= 0 || count >= input.count { continue }
            let spelling = candidate.consumedInputCount.map { String(input.prefix($0)) } ?? input
            let score = learning.rankingScore(for: candidate, input: spelling, now: now, context: context)
            if let previous = best[candidate.id], previous.score > score
                || (previous.score == score && !candidate.isUserPhrase) { continue }
            best[candidate.id] = (candidate, score)
        }
        let merged = best.values
            .sorted {
                if $0.candidate.isPartial != $1.candidate.isPartial { return !$0.candidate.isPartial }
                if $0.candidate.isPartial, $0.candidate.consumedInputCount != $1.candidate.consumedInputCount {
                    return ($0.candidate.consumedInputCount ?? 0) > ($1.candidate.consumedInputCount ?? 0)
                }
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.candidate.id < $1.candidate.id
            }
            .map(\.candidate)
        // Never drop an enabled language's candidates because another language matches.
        // Literal input stays available even with all language providers disabled.
        return merged + [InputCandidate(text: input, language: nil, score: 0)]
    }
}
