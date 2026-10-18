public struct CandidateEngine: Sendable {
    private let providers: [any CandidateProvider]

    public init(providers: [any CandidateProvider] = [EnglishCandidateProvider(), PinyinCandidateProvider()]) {
        self.providers = providers
    }

    public func candidates(for input: String, languages: Set<InputLanguage>) -> [InputCandidate] {
        guard !input.isEmpty else { return [] }
        var seen = Set<String>()
        let merged = providers.filter { languages.contains($0.language) }
            .flatMap { $0.candidates(for: input) }
            .filter { seen.insert($0.id).inserted }
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.id < $1.id
            }
        // Never drop an enabled language's candidates because another language matches.
        // Literal input stays available even with all language providers disabled.
        return merged + [InputCandidate(text: input, language: nil, score: 0)]
    }
}
