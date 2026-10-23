import Foundation

/// Explicitly saved phrases, independent of opt-in statistical learning.
public struct UserDictionary: Equatable, Sendable {
    public static let maximumEntries = 1_000
    public enum DictionaryError: Error, Equatable {
        case duplicatePhrase
        case duplicateIdentifier
        case capacityExceeded
    }

    private var phrases: [UUID: UserPhrase] = [:]
    private var identities: [String: UUID] = [:]
    private var codeIndex: [String: [UserPhrase]] = [:]
    private(set) var maximumCodeLength = 0

    /// Direct prefix choices are independent of the constructed-node fanout bound.
    /// The existing code index is already sorted and contains no chronological history.
    func directPhrases(for code: String) -> [UserPhrase] { codeIndex[code] ?? [] }

    public static func == (lhs: UserDictionary, rhs: UserDictionary) -> Bool { lhs.phrases == rhs.phrases }

    /// Bound constructed-path fanout; direct matches are returned separately without this cap.
    func phrases(for code: String) -> [UserPhrase] {
        var counts: [InputLanguage: Int] = [:]
        return (codeIndex[code] ?? []).filter {
            guard counts[$0.language, default: 0] < 12 else { return false }
            counts[$0.language, default: 0] += 1
            return true
        }
    }

    public init() {}

    public init(entries: [UserPhrase]) throws {
        guard entries.count <= Self.maximumEntries else { throw DictionaryError.capacityExceeded }
        for phrase in entries {
            guard phrases[phrase.id] == nil else { throw DictionaryError.duplicateIdentifier }
            try upsert(phrase)
        }
    }

    var phraseCount: Int { phrases.count }

    public var entries: [UserPhrase] {
        phrases.values.sorted {
            if $0.input != $1.input { return $0.input < $1.input }
            if $0.language != $1.language { return $0.language.rawValue < $1.language.rawValue }
            if $0.text != $1.text { return $0.text < $1.text }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    public mutating func upsert(_ phrase: UserPhrase) throws {
        let valid = try phrase.validated()
        guard identities[valid.identity].map({ $0 == valid.id }) ?? true else {
            throw DictionaryError.duplicatePhrase
        }
        guard phrases[valid.id] != nil || phrases.count < Self.maximumEntries else { throw DictionaryError.capacityExceeded }
        if let previous = phrases[valid.id] {
            identities.removeValue(forKey: previous.identity)
            removeFromIndex(previous)
        }
        phrases[valid.id] = valid
        identities[valid.identity] = valid.id
        codeIndex[valid.code, default: []].append(valid)
        codeIndex[valid.code]?.sort {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            if $0.text != $1.text { return $0.text < $1.text }
            if $0.language != $1.language { return $0.language.rawValue < $1.language.rawValue }
            return $0.id.uuidString < $1.id.uuidString
        }
        maximumCodeLength = max(maximumCodeLength, valid.code.count)
    }

    public mutating func remove(id: UUID) {
        if let phrase = phrases.removeValue(forKey: id) {
            identities.removeValue(forKey: phrase.identity)
            removeFromIndex(phrase)
        }
    }
    public mutating func removeAll() {
        phrases.removeAll(); identities.removeAll(); codeIndex.removeAll(); maximumCodeLength = 0
    }

    private mutating func removeFromIndex(_ phrase: UserPhrase) {
        let key = phrase.code
        codeIndex[key]?.removeAll { $0.id == phrase.id }
        if codeIndex[key]?.isEmpty == true { codeIndex.removeValue(forKey: key) }
        if key.count == maximumCodeLength { maximumCodeLength = codeIndex.keys.map(\.count).max() ?? 0 }
    }

    /// Import is additive and atomic; existing content wins, including its pin setting.
    @discardableResult
    public mutating func merge(_ imported: UserDictionary) throws -> Int {
        var updated = self
        var identities = Set(phrases.values.map(\.identity))
        var added = 0
        for phrase in imported.entries where identities.insert(phrase.identity).inserted {
            let id = updated.phrases[phrase.id] == nil ? phrase.id : UUID()
            let entry = try UserPhrase(id: id, input: phrase.input, text: phrase.text,
                                       language: phrase.language, isPinned: phrase.isPinned)
            try updated.upsert(entry)
            added += 1
        }
        self = updated
        return added
    }

    public func candidates(for input: String, languages: Set<InputLanguage>) -> [InputCandidate] {
        guard !input.isEmpty else { return [] }
        let english = LearningProfile.normalizedInput(input, language: .english)
        let chinese = LearningProfile.normalizedInput(input, language: .simplifiedChinese)
        return phrases.values.compactMap { phrase in
            guard languages.contains(phrase.language) else { return nil }
            let code = phrase.language == .english ? english : chinese
            guard phrase.input.hasPrefix(code) else { return nil }
            let exact = phrase.input == code
            let cost = CandidateScoring.initialLanguageCost
                + CandidateScoring.personalCost(codeLength: phrase.code.count,
                                                typedLength: code.filter { $0 != "'" }.count, pinned: phrase.isPinned)
            return InputCandidate(text: phrase.text, language: phrase.language,
                                  score: Int(-cost), isUserPhrase: true, rankingScore: -cost, hasCompletion: !exact,
                                  isPreferred: exact && phrase.isPinned)
        }
    }
}
