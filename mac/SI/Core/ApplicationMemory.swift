import Foundation

/// Bounded local archives. Application identity is supplied by the host adapter, never inferred here.
public struct ApplicationMemory: Equatable, Sendable {
    public static let maximumVocabularyEntries = 5_000
    public static let vocabularyRetentionDays = 90
    private var words: [String: ApplicationVocabularyEntry] = [:]
    private var profiles: [String: LearningProfile] = [:]

    public var vocabulary: [ApplicationVocabularyEntry] {
        words.values.sorted {
            $0.preference.lastUsed == $1.preference.lastUsed ? $0.id < $1.id : $0.preference.lastUsed > $1.preference.lastUsed
        }
    }
    public var applicationIDs: [String] { Set(words.values.map(\.applicationID)).sorted() }

    public init(vocabulary: [ApplicationVocabularyEntry] = [], now: Date = .now) {
        for entry in vocabulary where Self.valid(entry, now: now) {
            if let previous = words[entry.id], previous.preference.lastUsed >= entry.preference.lastUsed { continue }
            words[entry.id] = entry
        }
        prune(now: now)
    }

    @discardableResult
    public mutating func recordVocabulary(_ commit: InputCommit, applicationID: String, now: Date = .now) -> Bool {
        guard Self.validApplicationID(applicationID), let candidate = commit.candidate, candidate.canLearn,
              commit.reason == .explicitSelection || commit.reason == .defaultAcceptance else { return false }
        // Usage includes first choices; only explicit nonfirst choices can adjust ranking.
        let input = LearningProfile.normalizedInput(commit.input, language: candidate.language ?? .english)
        let identity = LearnedPreference.identity(input: input, language: candidate.language ?? .english,
                                                  text: candidate.text, isMixed: candidate.isMixed)
        let previous = words["\(applicationID.utf8.count):\(applicationID)\(identity)"].flatMap {
            now.timeIntervalSince($0.preference.lastUsed) < Double(Self.vocabularyRetentionDays) * 86_400 ? $0 : nil
        }
        var strength = previous.map { LearningProfile.decayedStrength($0.preference, now: now) } ?? 0
        var corrections = previous?.correctionCount ?? 0
        if commit.reason == .explicitSelection {
            corrections = min(1_000_000, corrections + 1)
            if corrections % 3 == 0 {
                // Store the inverse of the shared logarithmic score: one point per three corrections.
                let bonus = min(32, 12 * log2(1 + strength) + 1)
                strength = exp2(bonus / 12) - 1
            }
        }
        let preference = LearnedPreference(input: input, text: candidate.text, language: candidate.language ?? .english,
                                           strength: strength, lastUsed: now, isMixed: candidate.isMixed)
        let entry = ApplicationVocabularyEntry(applicationID: applicationID, preference: preference,
                                               count: min(1_000_000, (previous?.count ?? 0) + 1),
                                               baseScore: candidate.rankingScore, lexicalTokenCount: candidate.lexicalTokenCount,
                                               correctionCount: corrections)
        guard Self.valid(entry, now: now) else { return false }
        words[entry.id] = entry
        var applicationProfile = profiles[applicationID] ?? LearningProfile()
        applicationProfile.setPreference(preference, now: now)
        profiles[applicationID] = applicationProfile
        if words.count > Self.maximumVocabularyEntries { prune(now: now) }
        return true
    }

    public func snapshot(applicationID: String, vocabularyEnabled: Bool,
                         now: Date = .now) -> ApplicationMemorySnapshot {
        ApplicationMemorySnapshot(vocabulary: vocabularyEnabled ? words.values.filter { $0.applicationID == applicationID } : [],
                                  now: now,
                                  learning: vocabularyEnabled ? profiles[applicationID] ?? LearningProfile() : LearningProfile())
    }

    public mutating func removeVocabulary(id: String) {
        if let removed = words.removeValue(forKey: id) { profiles[removed.applicationID]?.remove(id: removed.preference.id) }
    }
    public mutating func clearVocabulary(applicationID: String? = nil) {
        if let applicationID {
            words = words.filter { $0.value.applicationID != applicationID }
            profiles.removeValue(forKey: applicationID)
        } else { words.removeAll(); profiles.removeAll() }
    }
    public mutating func prune(now: Date = .now) {
        words = words.filter { Self.valid($0.value, now: now) }
        if words.count > Self.maximumVocabularyEntries {
            words = Dictionary(uniqueKeysWithValues: vocabulary.prefix(Self.maximumVocabularyEntries).map { ($0.id, $0) })
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
            && (0...entry.count).contains(entry.correctionCount)
            && entry.baseScore.isFinite && abs(entry.baseScore) <= 1_000_000
            && entry.preference.context == nil && (entry.lexicalTokenCount.map { (1...512).contains($0) } ?? true)
            && LearningProfile.isValid(entry.preference, now: now, allowsZeroStrength: true)
    }

}
