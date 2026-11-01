import Foundation

/// Immutable global vocabulary, suppressed entirely when learning is disabled or input is secure.
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
        self.learning = learning ?? LearningProfile(entries: vocabulary.map(\.preference), now: now, retainsIndefinitely: true)
    }

    /// Exact normalized source spelling only: never promote a prefix because its remainder matches elsewhere.
    func preferredCandidateID(for input: String, languages: Set<InputLanguage>) -> String? {
        let english = LearningProfile.normalizedInput(input, language: .english)
        let chinese = LearningProfile.normalizedInput(input, language: .simplifiedChinese)
        let selected = vocabulary.lazy.filter { entry in
            let word = entry.preference
            return entry.lastSelected != nil && languages.contains(word.language)
                && (word.mixed != true || languages.contains(.english))
                && word.input == (word.language == .english ? english : chinese)
        }.max {
            if $0.lastSelected != $1.lastSelected { return ($0.lastSelected ?? .distantPast) < ($1.lastSelected ?? .distantPast) }
            return $0.id > $1.id
        }
        guard let word = selected?.preference else { return nil }
        return InputCandidate(text: word.text, language: word.language, score: 0, isMixed: word.mixed == true).id
    }

    func vocabularyCandidates(for input: String, languages: Set<InputLanguage>, now: Date) -> [InputCandidate] {
        vocabulary.sorted { $0.id < $1.id }.compactMap { entry in
            let word = entry.preference
            // A single correction is sufficient to retain a candidate even before frequency rewards accrue.
            guard word.strength > 0 || entry.lastSelected != nil,
                  languages.contains(word.language), word.mixed != true || languages.contains(.english) else { return nil }
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
