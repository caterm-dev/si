/// Endpoint languages for lexical spacing and continuation transition costs.
struct CandidateLanguageBoundary: Hashable, Sendable {
    var firstLanguage = 0
    var lastLanguage = 0

    static func english() -> Self { Self(firstLanguage: 2, lastLanguage: 2) }
    static func chinese() -> Self { Self(firstLanguage: 1, lastLanguage: 1) }

    func appending(language: Int) -> Self {
        Self(firstLanguage: firstLanguage == 0 ? language : firstLanguage, lastLanguage: language)
    }

    static func joining(_ prefix: InputCandidate, to suffix: InputCandidate) -> Double {
        guard let before = prefix.languageBoundary, let after = suffix.languageBoundary else { return 0 }
        return CandidateScoring.initialLanguageCost
            - CandidateScoring.languageCost(previous: before.lastLanguage, next: after.firstLanguage)
    }

    static func combining(_ before: Self, _ after: Self) -> Self {
        Self(firstLanguage: before.firstLanguage, lastLanguage: after.lastLanguage)
    }
}
