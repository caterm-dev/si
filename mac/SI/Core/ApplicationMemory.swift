import Foundation

/// Bounded local archives. Application identity is supplied by the host adapter, never inferred here.
public struct ApplicationMemory: Equatable, Sendable {
    public static let maximumVocabularyEntries = 5_000
    public static let maximumHistoryEntries = 1_000
    public static let vocabularyRetentionDays = 90
    public static let historyRetentionDays = 30
    private var words: [String: ApplicationVocabularyEntry] = [:]
    private var histories: [String: ApplicationHistoryEntry] = [:]
    private var profiles: [String: LearningProfile] = [:]

    public var vocabulary: [ApplicationVocabularyEntry] {
        words.values.sorted {
            $0.preference.lastUsed == $1.preference.lastUsed ? $0.id < $1.id : $0.preference.lastUsed > $1.preference.lastUsed
        }
    }
    public var history: [ApplicationHistoryEntry] {
        histories.values.sorted { $0.lastUsed == $1.lastUsed ? $0.id < $1.id : $0.lastUsed > $1.lastUsed }
    }
    public var applicationIDs: [String] { Set(words.values.map(\.applicationID) + histories.values.map(\.applicationID)).sorted() }

    public init(vocabulary: [ApplicationVocabularyEntry] = [], history: [ApplicationHistoryEntry] = [], now: Date = .now) {
        for entry in vocabulary where Self.valid(entry, now: now) {
            if let previous = words[entry.id], previous.preference.lastUsed >= entry.preference.lastUsed { continue }
            words[entry.id] = entry
        }
        for entry in history where Self.valid(entry, now: now) {
            if let previous = histories[entry.id], previous.lastUsed >= entry.lastUsed { continue }
            histories[entry.id] = entry
        }
        prune(now: now)
    }

    @discardableResult
    public mutating func recordVocabulary(_ commit: InputCommit, applicationID: String, now: Date = .now) -> Bool {
        guard Self.validApplicationID(applicationID), let candidate = commit.candidate, candidate.canLearn,
              commit.reason == .explicitSelection || commit.reason == .defaultAcceptance else { return false }
        // Per-app usage counts default acceptance too, under its own explicit opt-in.
        let choice = InputCommit(input: commit.input, candidate: candidate, reason: .explicitSelection)
        let input = LearningProfile.normalizedInput(commit.input, language: candidate.language ?? .english)
        let identity = LearnedPreference.identity(input: input, language: candidate.language ?? .english,
                                                  text: candidate.text, isMixed: candidate.isMixed)
        let previous = words["\(applicationID.utf8.count):\(applicationID)\(identity)"].flatMap {
            now.timeIntervalSince($0.preference.lastUsed) < Double(Self.vocabularyRetentionDays) * 86_400 ? $0 : nil
        }
        var profile = LearningProfile(entries: previous.map { [$0.preference] } ?? [], now: now)
        guard profile.record(choice, now: now), let preference = profile.entries.first else { return false }
        let entry = ApplicationVocabularyEntry(applicationID: applicationID, preference: preference,
                                               count: min(1_000_000, (previous?.count ?? 0) + 1),
                                               baseScore: candidate.rankingScore, lexicalTokenCount: candidate.lexicalTokenCount)
        guard Self.valid(entry, now: now) else { return false }
        words[entry.id] = entry
        var applicationProfile = profiles[applicationID] ?? LearningProfile()
        _ = applicationProfile.record(choice, now: now)
        profiles[applicationID] = applicationProfile
        if words.count > Self.maximumVocabularyEntries { prune(now: now) }
        return true
    }

    @discardableResult
    public mutating func recordHistory(_ entry: ApplicationHistoryEntry, now: Date = .now) -> Bool {
        guard Self.valid(entry, now: now) else { return false }
        let previous = histories[entry.id].flatMap {
            now.timeIntervalSince($0.lastUsed) < Double(Self.historyRetentionDays) * 86_400 ? $0 : nil
        }
        let saved = ApplicationHistoryEntry(applicationID: entry.applicationID, input: entry.input, text: entry.text,
                                            languages: entry.languages, count: min(1_000_000, (previous?.count ?? 0) + 1),
                                            lastUsed: now)
        histories[saved.id] = saved
        if histories.count > Self.maximumHistoryEntries { prune(now: now) }
        return true
    }

    public func snapshot(applicationID: String, vocabularyEnabled: Bool, historyEnabled: Bool,
                         now: Date = .now) -> ApplicationMemorySnapshot {
        ApplicationMemorySnapshot(vocabulary: vocabularyEnabled ? words.values.filter { $0.applicationID == applicationID } : [],
                                  history: historyEnabled ? histories.values.filter { $0.applicationID == applicationID } : [], now: now,
                                  learning: vocabularyEnabled ? profiles[applicationID] ?? LearningProfile() : LearningProfile())
    }

    public mutating func removeVocabulary(id: String) {
        if let removed = words.removeValue(forKey: id) { profiles[removed.applicationID]?.remove(id: removed.preference.id) }
    }
    public mutating func removeHistory(id: String) { histories.removeValue(forKey: id) }
    public mutating func clearVocabulary(applicationID: String? = nil) {
        if let applicationID {
            words = words.filter { $0.value.applicationID != applicationID }
            profiles.removeValue(forKey: applicationID)
        } else { words.removeAll(); profiles.removeAll() }
    }
    public mutating func clearHistory(applicationID: String? = nil) {
        if let applicationID { histories = histories.filter { $0.value.applicationID != applicationID } }
        else { histories.removeAll() }
    }

    public mutating func prune(now: Date = .now) {
        words = words.filter { Self.valid($0.value, now: now) }
        histories = histories.filter { Self.valid($0.value, now: now) }
        if words.count > Self.maximumVocabularyEntries {
            words = Dictionary(uniqueKeysWithValues: vocabulary.prefix(Self.maximumVocabularyEntries).map { ($0.id, $0) })
        }
        if histories.count > Self.maximumHistoryEntries {
            histories = Dictionary(uniqueKeysWithValues: history.prefix(Self.maximumHistoryEntries).map { ($0.id, $0) })
        }
        profiles = Dictionary(grouping: words.values, by: \.applicationID).mapValues {
            LearningProfile(entries: $0.map(\.preference), now: now)
        }
    }

    private static func validApplicationID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 255
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static func valid(_ entry: ApplicationVocabularyEntry, now: Date) -> Bool {
        validApplicationID(entry.applicationID) && (1...1_000_000).contains(entry.count)
            && entry.baseScore.isFinite && abs(entry.baseScore) <= 1_000_000
            && entry.preference.context == nil && (entry.lexicalTokenCount.map { (1...512).contains($0) } ?? true)
            && !LearningProfile(entries: [entry.preference], now: now).entries.isEmpty
    }

    private static func valid(_ entry: ApplicationHistoryEntry, now: Date) -> Bool {
        validApplicationID(entry.applicationID) && (1...1_000_000).contains(entry.count)
            && !entry.input.trimmingCharacters(in: .whitespaces).isEmpty
            && !entry.text.trimmingCharacters(in: .whitespaces).isEmpty
            && entry.input.utf8.count <= InputHistoryDraft.maximumBytes && entry.text.utf8.count <= InputHistoryDraft.maximumBytes
            && !entry.input.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
            && !entry.text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
            && entry.lastUsed.timeIntervalSince1970.isFinite && entry.lastUsed <= now.addingTimeInterval(300)
            && now.timeIntervalSince(entry.lastUsed) < Double(historyRetentionDays) * 86_400
    }
}
