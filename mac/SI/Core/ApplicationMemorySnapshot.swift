import Foundation

/// Immutable per-app data passed to the same engine used by input and preview.
public struct ApplicationMemorySnapshot: Equatable, Sendable {
    public static let empty = ApplicationMemorySnapshot()
    private let revision = UUID()
    public let vocabulary: [ApplicationVocabularyEntry]
    public let history: [ApplicationHistoryEntry]
    public let learning: LearningProfile
    public var historyPrefix = InputHistoryDraft()

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.revision == rhs.revision && lhs.historyPrefix == rhs.historyPrefix
    }

    public init(vocabulary: [ApplicationVocabularyEntry] = [], history: [ApplicationHistoryEntry] = [], now: Date = .now,
                learning: LearningProfile? = nil) {
        self.vocabulary = vocabulary
        self.history = history
        self.learning = learning ?? LearningProfile(entries: vocabulary.map(\.preference), now: now)
    }

    func vocabularyCandidates(for input: String, languages: Set<InputLanguage>, now: Date) -> [InputCandidate] {
        vocabulary.sorted { $0.id < $1.id }.compactMap { entry in
            let word = entry.preference
            guard languages.contains(word.language), word.mixed != true || languages.contains(.english),
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

    func historyCandidates(for input: String, languages: Set<InputLanguage>, now: Date) -> [InputCandidate] {
        guard !input.isEmpty, !languages.isEmpty, !historyPrefix.isInvalid else { return [] }
        return history.filter {
            $0.languages.isSubset(of: languages)
                && now.timeIntervalSince($0.lastUsed) < Double(ApplicationMemory.historyRetentionDays) * 86_400
        }.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            if $0.lastUsed != $1.lastUsed { return $0.lastUsed > $1.lastUsed }
            return $0.id < $1.id
        }.compactMap { entry -> InputCandidate? in
            // Exact committed bytes are required before offering only the uncommitted suffix.
            guard entry.text.utf8.starts(with: historyPrefix.text.utf8),
                  entry.input.utf8.starts(with: historyPrefix.input.utf8) else { return nil }
            let source = String(decoding: entry.input.utf8.dropFirst(historyPrefix.input.utf8.count), as: UTF8.self)
            let output = String(decoding: entry.text.utf8.dropFirst(historyPrefix.text.utf8.count), as: UTF8.self)
            guard !output.isEmpty, !output.utf8.elementsEqual(input.utf8) else { return nil }
            let spellingLanguage: InputLanguage = entry.languages.contains(.simplifiedChinese) ? .simplifiedChinese : .english
            let sourceKey = LearningProfile.normalizedInput(source, language: spellingLanguage)
            let inputKey = LearningProfile.normalizedInput(input, language: spellingLanguage)
            guard sourceKey.hasPrefix(inputKey) || output.utf8.starts(with: input.utf8) else { return nil }
            let mixed = entry.languages.count > 1
            let language: InputLanguage? = entry.languages.contains(.simplifiedChinese) ? .simplifiedChinese
                : entry.languages.contains(.english) ? .english : nil
            return InputCandidate(text: output, language: language, score: 0, isMixed: mixed,
                                  hasCompletion: true, isHistory: true, historyInput: source)
        }.reduce(into: [InputCandidate]()) { result, candidate in
            if result.count < 3 && !result.contains(where: { $0.id == candidate.id }) { result.append(candidate) }
        }
    }
}
