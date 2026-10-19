import Foundation

public struct EnglishCandidateProvider: CandidateProvider {
    public let language = InputLanguage.english

    public init() {}

    public func candidates(for input: String) -> [InputCandidate] {
        guard !input.isEmpty else { return [] }
        let key = input.lowercased()
        return EnglishLexicon.matches(for: key).map { word in
            InputCandidate(text: Self.adjustedCase(word, input: input), language: language,
                           score: word.lowercased() == key ? 110 : EnglishLexicon.completionScore(for: word), hasCompletion: word.lowercased() != key)
        }
    }

    static func adjustedCase(_ word: String, input: String) -> String {
        if input == input.uppercased() { return word.uppercased() }
        if input.first?.isUppercase == true { return word.prefix(1).uppercased() + word.dropFirst() }
        return word
    }
}
