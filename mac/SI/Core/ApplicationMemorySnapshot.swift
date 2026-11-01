import Foundation

/// Immutable per-app data passed to the same engine used by input and preview.
public struct ApplicationMemorySnapshot: Equatable, Sendable {
    public static let empty = ApplicationMemorySnapshot()
    private let revision = UUID()
    public let vocabulary: [ApplicationVocabularyEntry]
    public let learning: LearningProfile

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.revision == rhs.revision
    }

    public init(vocabulary: [ApplicationVocabularyEntry] = [], now: Date = .now,
                learning: LearningProfile? = nil) {
        self.vocabulary = vocabulary
        self.learning = learning ?? LearningProfile(entries: vocabulary.map(\.preference), now: now)
    }

    func vocabularyCandidates(for input: String, languages: Set<InputLanguage>, now: Date) -> [InputCandidate] {
        vocabulary.sorted { $0.id < $1.id }.compactMap { entry in
            let word = entry.preference
            // Usage-only rows must not change ranking by injecting cached completions either.
            guard word.strength > 0, languages.contains(word.language), word.mixed != true || languages.contains(.english),
                  now.timeIntervalSince(word.lastUsed) < Double(ApplicationMemory.vocabularyRetentionDays) * 86_400 else { return nil }
            let key = LearningProfile.normalizedInput(input, language: word.language)
            guard word.input.hasPrefix(key) else { return nil }
            let exact = word.input == key
            let score = entry.baseScore - Double(max(0, word.input.count - key.count)) * 2
            return InputCandidate(text: word.text, language: word.language, score: Int(score),
                                  isMixed: word.mixed == true, rankingScore: score,
                                  hasCompletion: !exact, lexicalTokenCount: entry.lexicalTokenCount,
                                  isApplicationVocabulary: true)
        }
    }

}
