import Foundation

/// Bounded aggregate preferences, never a chronological input history.
public struct LearningProfile: Sendable, Equatable {
    public static let maximumEntries = 5_000
    public static let retentionDays = 90
    private static let halfLife: TimeInterval = 14 * 24 * 60 * 60
    private static let maximumStrength = 1_000.0
    private var records: [String: LearnedPreference] = [:]
    // Skip token lookups for spellings with no single-language frequency records.
    private var tokenInputs: [String: Int] = [:]
    private var rankingInputs: [String: Int] = [:]

    struct Ranking {
        private let profile: LearningProfile
        private let chinese: String
        private let english: String
        private let now: Date
        private let context: CandidateContext?
        let hasWholePreferences: Bool
        let isActive: Bool

        fileprivate init(profile: LearningProfile, input: String, now: Date, context: CandidateContext?) {
            self.profile = profile
            self.now = now
            self.context = context
            chinese = LearningProfile.normalizedInput(input, language: .simplifiedChinese)
            english = LearningProfile.normalizedInput(input, language: .english)
            hasWholePreferences = profile.rankingInputs[chinese] != nil || profile.rankingInputs[english] != nil
            isActive = !profile.records.isEmpty
        }

        func score(_ candidate: InputCandidate) -> Double {
            guard isActive, candidate.canLearn, let language = candidate.language else { return candidate.rankingScore }
            let values = hasWholePreferences
                ? profile.bonuses(for: candidate, normalizedInput: language == .english ? english : chinese,
                                  language: language, now: now, context: context) : (frequency: 0.0, contextual: 0.0)
            return candidate.rankingScore + max(candidate.tokenLearningBonus, values.frequency) + values.contextual
        }
    }

    public var entries: [LearnedPreference] {
        records.values.sorted {
            if $0.lastUsed != $1.lastUsed { return $0.lastUsed > $1.lastUsed }
            return $0.id < $1.id
        }
    }

    public init(entries: [LearnedPreference] = [], now: Date = .now) {
        for entry in entries where Self.isValid(entry, now: now) {
            if let previous = records[entry.id], previous.lastUsed >= entry.lastUsed { continue }
            records[entry.id] = entry
        }
        prune(now: now)
    }

    @discardableResult
    public mutating func record(_ commit: InputCommit, now: Date = .now, learnContext: Bool = false) -> Bool {
        guard commit.reason.learningWeight > 0,
              let candidate = commit.candidate, candidate.canLearn,
              let language = candidate.language else { return false }
        guard update(commit, candidate: candidate, language: language, context: nil, now: now) else { return false }
        if learnContext, let context = commit.context, context.isValid {
            _ = update(commit, candidate: candidate, language: language, context: context, now: now)
        }
        if records.count > Self.maximumEntries { prune(now: now) }
        return true
    }

    private mutating func update(_ commit: InputCommit, candidate: InputCandidate, language: InputLanguage,
                                 context: CandidateContext?, now: Date) -> Bool {
        let input = Self.normalizedInput(commit.input, language: language)
        let id = LearnedPreference.identity(input: input, language: language, text: candidate.text,
                                            isMixed: candidate.isMixed, context: context)
        let previous = records[id]
        let strength = min(Self.maximumStrength,
                           previous.map { Self.decayedStrength($0, now: now) } ?? 0) + commit.reason.learningWeight
        let entry = LearnedPreference(input: input, text: candidate.text, language: language,
                                      strength: min(Self.maximumStrength, strength), lastUsed: now,
                                      isMixed: candidate.isMixed, context: context)
        guard Self.isValid(entry, now: now) else { return false }
        records[id] = entry
        if previous == nil { rankingInputs[input, default: 0] += 1 }
        if previous == nil, Self.isTokenPreference(entry) { tokenInputs[input, default: 0] += 1 }
        return true
    }

    public func bonus(for candidate: InputCandidate, input: String, now: Date = .now,
                      context: CandidateContext? = nil) -> Double {
        let values = bonuses(for: candidate, input: input, now: now, context: context)
        return values.frequency + values.contextual
    }

    func bonuses(for candidate: InputCandidate, input: String, now: Date,
                 context: CandidateContext?) -> (frequency: Double, contextual: Double) {
        guard candidate.canLearn, let language = candidate.language else { return (0, 0) }
        let key = Self.normalizedInput(input, language: language)
        return bonuses(for: candidate, normalizedInput: key, language: language, now: now, context: context)
    }

    private func bonuses(for candidate: InputCandidate, normalizedInput key: String, language: InputLanguage,
                         now: Date, context: CandidateContext?) -> (frequency: Double, contextual: Double) {
        guard rankingInputs[key] != nil else { return (0, 0) }
        let id = LearnedPreference.identity(input: key, language: language, text: candidate.text, isMixed: candidate.isMixed)
        let base = weight(id: id, maximum: 32, now: now)
        guard let context, context.isValid else { return (base, 0) }
        let contextualID = LearnedPreference.identity(input: key, language: language, text: candidate.text,
                                                      isMixed: candidate.isMixed, context: context)
        return (base, weight(id: contextualID, maximum: 12, now: now))
    }

    func rankingScore(for candidate: InputCandidate, input: String, now: Date, context: CandidateContext?) -> Double {
        guard !records.isEmpty, candidate.canLearn else { return candidate.rankingScore }
        let values = bonuses(for: candidate, input: input, now: now, context: context)
        return candidate.rankingScore + max(candidate.tokenLearningBonus, values.frequency) + values.contextual
    }

    /// One source spelling is shared by a group of full/prefix candidates; normalize it once.
    func ranking(for input: String, now: Date, context: CandidateContext?) -> Ranking {
        Ranking(profile: self, input: input, now: now, context: context)
    }

    var hasTokenPreferences: Bool { !tokenInputs.isEmpty }

    func tokenBonus(input: String, text: String, language: InputLanguage, now: Date) -> Double {
        let key = Self.normalizedInput(input, language: language)
        guard hasTokenPreferences(for: key) else { return 0 }
        return tokenBonus(normalizedInput: key, text: text, language: language, now: now)
    }

    func hasTokenPreferences(for normalizedInput: String) -> Bool { tokenInputs[normalizedInput] != nil }

    func tokenBonus(normalizedInput: String, text: String, language: InputLanguage, now: Date) -> Double {
        // A standalone Chinese character is too ambiguous to transfer into unrelated compositions.
        guard language != .simplifiedChinese || text.count > 1 else { return 0 }
        return weight(id: LearnedPreference.identity(input: normalizedInput, language: language, text: text), maximum: 32, now: now)
    }

    private static func isTokenPreference(_ entry: LearnedPreference) -> Bool {
        entry.context == nil && entry.mixed != true && (entry.language != .simplifiedChinese || entry.text.count > 1)
    }

    private func weight(id: String, maximum: Double, now: Date) -> Double {
        guard let entry = records[id], Self.isValid(entry, now: now) else { return 0 }
        return min(maximum, 12 * log2(1 + Self.decayedStrength(entry, now: now)))
    }

    public mutating func remove(id: String) {
        guard let entry = records.removeValue(forKey: id) else { return }
        if rankingInputs[entry.input] == 1 { rankingInputs.removeValue(forKey: entry.input) }
        else { rankingInputs[entry.input, default: 0] -= 1 }
        guard Self.isTokenPreference(entry) else { return }
        if tokenInputs[entry.input] == 1 { tokenInputs.removeValue(forKey: entry.input) }
        else { tokenInputs[entry.input, default: 0] -= 1 }
    }
    public mutating func removeAll() {
        records.removeAll()
        tokenInputs.removeAll()
        rankingInputs.removeAll()
    }

    public mutating func prune(now: Date = .now) {
        records = records.filter { Self.isValid($0.value, now: now) }
        if records.count > Self.maximumEntries {
            records = Dictionary(uniqueKeysWithValues: entries.prefix(Self.maximumEntries).map { ($0.id, $0) })
        }
        tokenInputs.removeAll(keepingCapacity: true)
        rankingInputs.removeAll(keepingCapacity: true)
        for entry in records.values {
            rankingInputs[entry.input, default: 0] += 1
            if Self.isTokenPreference(entry) { tokenInputs[entry.input, default: 0] += 1 }
        }
    }

    static func normalizedInput(_ input: String, language: InputLanguage) -> String {
        let lower = input.lowercased()
        // Explicit syllable boundaries distinguish readings such as xian and xi'an.
        guard language == .simplifiedChinese else { return lower }
        guard lower.contains("u:") || lower.contains("ü") else { return lower }
        return lower.replacing("u:", with: "v").replacing("ü", with: "v")
    }

    private static func decayedStrength(_ entry: LearnedPreference, now: Date) -> Double {
        entry.strength * pow(0.5, max(0, now.timeIntervalSince(entry.lastUsed)) / halfLife)
    }

    private static func isValid(_ entry: LearnedPreference, now: Date) -> Bool {
        !entry.input.isEmpty && entry.input.utf8.count <= 128
            && entry.input.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.letters.contains($0) || $0 == "'") }
            && !entry.text.isEmpty && entry.text.utf8.count <= 512
            && !entry.text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            && entry.strength.isFinite && entry.strength > 0 && entry.strength <= maximumStrength
            && (entry.context?.isValid ?? true)
            && (entry.mixed != true || entry.language == .simplifiedChinese)
            && entry.lastUsed.timeIntervalSince1970.isFinite
            && entry.lastUsed <= now.addingTimeInterval(5 * 60)
            && now.timeIntervalSince(entry.lastUsed) < Double(retentionDays) * 24 * 60 * 60
    }
}
