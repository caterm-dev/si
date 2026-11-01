import Foundation

/// Bounded global vocabulary. Consent and secure-input boundaries are enforced by the host adapter.
public struct ApplicationMemory: Equatable, Sendable {
    public static let maximumVocabularyEntries = 5_000
    private var words: [String: ApplicationVocabularyEntry] = [:]
    private var selectedIDs: [String: String] = [:]
    private var profile = LearningProfile(retainsIndefinitely: true)

    public var vocabulary: [ApplicationVocabularyEntry] {
        words.values.sorted {
            $0.preference.lastUsed == $1.preference.lastUsed ? $0.id < $1.id : $0.preference.lastUsed > $1.preference.lastUsed
        }
    }

    public init(vocabulary: [ApplicationVocabularyEntry] = [], now: Date = .now) {
        for entry in vocabulary where Self.valid(entry, now: now) {
            guard let previous = words[entry.id] else { words[entry.id] = entry; continue }
            // Merge old app scopes without multiplying their ranking strength or inventing a selection time.
            let latest: ApplicationVocabularyEntry
            if entry.preference.lastUsed != previous.preference.lastUsed {
                latest = entry.preference.lastUsed > previous.preference.lastUsed ? entry : previous
            } else if entry.baseScore != previous.baseScore {
                latest = entry.baseScore > previous.baseScore ? entry : previous
            } else {
                latest = (entry.lexicalTokenCount ?? 512) < (previous.lexicalTokenCount ?? 512) ? entry : previous
            }
            let old = latest.preference
            let preference = LearnedPreference(input: old.input, text: old.text, language: old.language,
                strength: max(entry.preference.strength, previous.preference.strength), lastUsed: old.lastUsed,
                isMixed: old.mixed == true)
            words[entry.id] = ApplicationVocabularyEntry(preference: preference,
                count: min(1_000_000, entry.count + previous.count), baseScore: latest.baseScore,
                lexicalTokenCount: latest.lexicalTokenCount,
                correctionCount: min(1_000_000, entry.correctionCount + previous.correctionCount),
                lastSelected: [entry.lastSelected, previous.lastSelected].compactMap { $0 }.max())
        }
        prune(now: now)
    }

    @discardableResult
    public mutating func recordVocabulary(_ commit: InputCommit, now: Date = .now) -> Bool {
        guard let candidate = commit.candidate, candidate.canLearn,
              commit.reason == .explicitSelection || commit.reason == .defaultAcceptance else { return false }
        let input = LearningProfile.normalizedInput(commit.input, language: candidate.language ?? .english)
        let identity = LearnedPreference.identity(input: input, language: candidate.language ?? .english,
                                                  text: candidate.text, isMixed: candidate.isMixed)
        let previous = words[identity]
        var strength = previous?.preference.strength ?? 0
        var corrections = previous?.correctionCount ?? 0
        if commit.reason == .explicitSelection {
            corrections = min(1_000_000, corrections + 1)
            if corrections % 3 == 0 {
                let bonus = min(32, 12 * log2(1 + strength) + 1)
                strength = exp2(bonus / 12) - 1
            }
        }
        let preference = LearnedPreference(input: input, text: candidate.text, language: candidate.language ?? .english,
                                           strength: strength, lastUsed: now, isMixed: candidate.isMixed)
        let entry = ApplicationVocabularyEntry(preference: preference,
            count: min(1_000_000, (previous?.count ?? 0) + 1), baseScore: candidate.rankingScore,
            lexicalTokenCount: candidate.lexicalTokenCount, correctionCount: corrections,
            lastSelected: commit.reason == .explicitSelection ? now : previous?.lastSelected)
        guard Self.valid(entry, now: now) else { return false }
        if commit.reason == .explicitSelection {
            // One latest choice per spelling, independent of timestamp ties or changes to the wall clock.
            if let oldID = selectedIDs[input], oldID != entry.id, let old = words[oldID] {
                words[oldID] = ApplicationVocabularyEntry(preference: old.preference, count: old.count,
                    baseScore: old.baseScore, lexicalTokenCount: old.lexicalTokenCount, correctionCount: old.correctionCount)
            }
            selectedIDs[input] = entry.id
        }
        words[entry.id] = entry
        profile.setPreference(preference, now: now)
        if words.count > Self.maximumVocabularyEntries { prune(now: now) }
        return true
    }

    public func snapshot(vocabularyEnabled: Bool,
                         now: Date = .now) -> ApplicationMemorySnapshot {
        ApplicationMemorySnapshot(vocabulary: vocabularyEnabled ? Array(words.values) : [], now: now,
                                  learning: vocabularyEnabled ? profile : LearningProfile(retainsIndefinitely: true))
    }

    public mutating func removeVocabulary(id: String) {
        if let removed = words.removeValue(forKey: id) {
            profile.remove(id: removed.preference.id)
            if selectedIDs[removed.preference.input] == id { selectedIDs.removeValue(forKey: removed.preference.input) }
        }
    }
    public mutating func clearVocabulary() {
        words.removeAll()
        selectedIDs.removeAll()
        profile.removeAll()
    }
    public mutating func prune(now: Date = .now) {
        words = words.filter { Self.valid($0.value, now: now) }
        if words.count > Self.maximumVocabularyEntries {
            words = Dictionary(uniqueKeysWithValues: vocabulary.prefix(Self.maximumVocabularyEntries).map { ($0.id, $0) })
        }
        selectedIDs.removeAll(keepingCapacity: true)
        // Sorted order gives deterministic winners for equal timestamps in imported archives.
        for entry in vocabulary.reversed() {
            guard let selected = entry.lastSelected else { continue }
            let key = entry.preference.input
            if let oldID = selectedIDs[key], let oldSelected = words[oldID]?.lastSelected, oldSelected > selected { continue }
            selectedIDs[key] = entry.id
        }
        for entry in words.values where entry.lastSelected != nil && selectedIDs[entry.preference.input] != entry.id {
            words[entry.id] = ApplicationVocabularyEntry(preference: entry.preference, count: entry.count,
                baseScore: entry.baseScore, lexicalTokenCount: entry.lexicalTokenCount, correctionCount: entry.correctionCount)
        }
        profile = LearningProfile(entries: words.values.map(\.preference), now: now, retainsIndefinitely: true)
    }

    private static func valid(_ entry: ApplicationVocabularyEntry, now: Date) -> Bool {
        (1...1_000_000).contains(entry.count) && (0...entry.count).contains(entry.correctionCount)
            && entry.baseScore.isFinite && abs(entry.baseScore) <= 1_000_000
            && entry.preference.context == nil && (entry.lexicalTokenCount.map { (1...512).contains($0) } ?? true)
            && (entry.lastSelected.map {
                entry.correctionCount > 0 && $0.timeIntervalSince1970.isFinite && $0 <= entry.preference.lastUsed
            } ?? true)
            && LearningProfile.isValid(entry.preference, now: now, allowsZeroStrength: true, retainsIndefinitely: true)
    }
}
