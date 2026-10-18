import Foundation

/// A small, original vocabulary for exercising the pipeline, not a full dictionary.
public struct EnglishCandidateProvider: CandidateProvider {
    public let language = InputLanguage.english
    private let words = [
        "a", "an", "and", "app", "apple", "are", "as", "at", "be", "build",
        "can", "code", "day", "developer", "do", "for", "good", "great",
        "ha", "had", "happy", "he", "hello", "help", "her", "hi", "home",
        "I", "in", "input", "is", "it", "language", "mac", "me", "my",
        "name", "new", "no", "of", "on", "open", "or", "project", "see",
        "she", "ship", "shirt", "should", "so", "source", "swift", "test",
        "the", "there", "this", "time", "to", "today", "we", "with", "work",
        "world", "write", "yes", "you", "your",
    ]

    public init() {}

    public func candidates(for input: String) -> [InputCandidate] {
        guard !input.isEmpty else { return [] }
        let key = input.lowercased()
        return words.filter { $0.lowercased().hasPrefix(key) }.map { word in
            let text = input.first?.isUppercase == true ? word.capitalized : word
            return InputCandidate(text: text, language: language, score: word.lowercased() == key ? 110 : 60)
        }
    }
}
