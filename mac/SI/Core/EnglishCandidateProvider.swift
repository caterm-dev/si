import Foundation

public struct EnglishCandidateProvider: CandidateProvider {
    public let language = InputLanguage.english

    public init() {}

    public func candidates(for input: String) -> [InputCandidate] {
        guard !input.isEmpty else { return [] }
        let key = input.lowercased()
        let length = key.utf8.count
        let style = EnglishLexicon.CaseStyle(input: input)
        return EnglishLexicon.matches(for: key).map { entry in
            InputCandidate(text: entry.text(for: style), language: language,
                           score: entry.length == length ? 110 : entry.completionScore,
                           hasCompletion: entry.length != length)
        }
    }
}
