/// One immutable vocabulary shared by direct English lookup and mixed decoding.
/// Generated entries are sorted by their case-insensitive ASCII lookup spelling.
enum EnglishLexicon {
    static let words = EnglishLexiconData.words
    static let keys = words.map { $0.lowercased() }
    static let maximumLength = words.map(\.count).max() ?? 0

    static func prepare() {
        _ = keys
        _ = maximumLength
        _ = EnglishLexiconData.completionScores
    }

    static func completionScore(for word: String) -> Int {
        EnglishLexiconData.completionScores[word.lowercased()] ?? 75
    }

    static func exactMatch(for key: String) -> String? {
        let index = lowerBound(key)
        guard index < keys.count, keys[index] == key else { return nil }
        return words[index]
    }

    static func matches(for key: String) -> ArraySlice<String> {
        guard !key.isEmpty, key.utf8.allSatisfy({ $0 >= 97 && $0 <= 122 }) else {
            return words[0..<0]
        }
        // All stored lookup bytes are a...z, so { is above every possible suffix.
        return words[lowerBound(key)..<lowerBound(key + "{")]
    }

    static func completions(for key: String) -> ArraySlice<String> {
        guard key.count >= 2 else { return words[0..<0] }
        let matches = matches(for: key)
        return matches.first?.lowercased() == key ? matches.dropFirst() : matches
    }

    private static func lowerBound(_ key: String) -> Int {
        var lower = 0
        var upper = keys.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if keys[middle] < key { lower = middle + 1 } else { upper = middle }
        }
        return lower
    }
}
