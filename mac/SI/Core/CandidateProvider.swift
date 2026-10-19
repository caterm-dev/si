/// A provider proposes candidates without choosing an active input language.
public protocol CandidateProvider: Sendable {
    var language: InputLanguage { get }
    var requiredLanguages: Set<InputLanguage> { get }
    func candidates(for input: String) -> [InputCandidate]
}

extension CandidateProvider {
    public var requiredLanguages: Set<InputLanguage> { [language] }
}
