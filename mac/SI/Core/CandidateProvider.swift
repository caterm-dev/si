/// A provider proposes candidates without choosing an active input language.
public protocol CandidateProvider: Sendable {
    var language: InputLanguage { get }
    func candidates(for input: String) -> [InputCandidate]
}
