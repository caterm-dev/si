import Foundation

/// Production and injected lexicons implement the same lookup and feed the same decoder.
struct ChineseLexicon: Sendable {
    static let standard = ChineseLexicon()
    private let database: LexiconDatabase?
    private let entries: [DictionaryLexeme]
    private let exact: [String: [DictionaryLexeme]]
    let bigram: ChineseNgramTable?
    let trigram: ChineseNgramTable?
    var isAvailable: Bool { database?.isAvailable ?? !entries.isEmpty }

    private init() {
        database = LexiconDatabase(url: ChineseResources.url("si-pinyin", extension: "sqlite"))
        entries = []
        exact = [:]
        bigram = ChineseNgramTable(url: ChineseResources.url("msime-bigram", extension: "bin"))
        trigram = ChineseNgramTable(url: ChineseResources.url("msime-trigram", extension: "bin"))
    }

    init(entries: [PinyinLexiconEntry]) {
        database = nil
        self.entries = entries.enumerated().compactMap { index, entry in
            guard !entry.text.isEmpty, !entry.syllables.isEmpty, entry.code.count <= 64,
                  (0...200).contains(entry.score),
                  entry.text.utf8.count <= PinyinDecoder.maximumOutputBytes,
                  entry.syllables.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (97...122).contains($0) } }) else { return nil }
            let weight = entry.usesUpstreamWeight ? Int64(clamping: entry.upstreamWeight ?? 1)
                : Int64(exp2(Double(entry.score) / 10))
            return DictionaryLexeme(text: entry.text, reading: entry.syllables, weight: weight, ordinal: Int64(index))
        }
        exact = Dictionary(grouping: self.entries, by: \.key)
        bigram = nil
        trigram = nil
    }

    func exactMatches(_ segments: [String], limit: Int? = nil) -> [DictionaryLexeme] {
        let segments = segments.map(ChineseSyllables.canonical)
        return rows(segments: segments, kind: .exact, limit: limit)
    }

    /// Alternative cuts are batched by table, with a row budget for each table. MSIME
    /// then stable-sorts the concatenated pages and deduplicates when merging candidates.
    func exactAlternatives(_ readings: [[String]], limit: Int = 128) -> [DictionaryLexeme] {
        var tables: [String] = []
        var groups: [String: [String]] = [:]
        for reading in readings {
            let normalized = reading.map(ChineseSyllables.canonical)
            guard normalized.allSatisfy(ChineseSyllables.complete.contains),
                  let first = normalized.first?.first, "abcdefghjklmnopqrstwxyz".contains(first) else { continue }
            let bucket = normalized.count <= 7 ? String(normalized.count) : "others"
            let table = "tbl_\(bucket)_\(first)"
            let key = normalized.joined(separator: "'")
            if groups[table] == nil { tables.append(table) }
            if !(groups[table] ?? []).contains(key) { groups[table, default: []].append(key) }
        }
        var result: [DictionaryLexeme] = []
        for table in tables.sorted() {
            guard let keys = groups[table] else { continue }
            if let database {
                let placeholders = Array(repeating: "?", count: keys.count).joined(separator: ",")
                result += database.rows(table: table, condition: "key IN (\(placeholders))", values: keys, limit: limit)
            } else {
                result += ranked(keys.flatMap { exact[$0] ?? [] }).prefix(limit)
            }
        }
        return result.sorted { $0.weight > $1.weight }
    }

    func matches(_ segments: [String], limit: Int? = nil) -> [DictionaryLexeme] {
        guard !segments.isEmpty else { return [] }
        let normalized = segments.map(ChineseSyllables.canonical)
        // The single-letter channel deliberately includes all syllables with that initial,
        // even when the letter is itself an intact syllable (a/e/o).
        if normalized.count == 1, normalized[0].count == 1 {
            return rows(segments: normalized, kind: .prefix, limit: min(limit ?? 24, 24))
        }
        if normalized.allSatisfy(ChineseSyllables.complete.contains) {
            let exact = rows(segments: normalized, kind: .exact, limit: limit)
            if !exact.isEmpty { return uniqueWords(exact) }
        }
        let prefix = rows(segments: normalized, kind: .prefix, limit: limit)
        if !prefix.isEmpty { return uniqueWords(prefix) }
        guard normalized.count > 1,
              normalized.dropLast().contains(where: { $0.count == 1 || ["zh", "ch", "sh"].contains($0) }) else { return [] }
        return uniqueWords(rows(segments: normalized, kind: .initials, limit: limit))
    }

    func completions(_ segments: [String], limit: Int = 3) -> [DictionaryLexeme] {
        guard segments.count >= 2, segments.allSatisfy(ChineseSyllables.complete.contains) else { return [] }
        var result: [DictionaryLexeme] = []
        for length in segments.count + 1...segments.count + min(3, max(1, 8 - segments.count)) {
            let rows = rows(segments: segments.map(ChineseSyllables.canonical), kind: .longer(length), limit: limit)
            result.append(contentsOf: rows)
        }
        var seen = Set<String>()
        return Array(ranked(result).filter { seen.insert($0.text).inserted }.prefix(limit))
    }

    private enum Lookup { case exact, prefix, initials, longer(Int) }

    private func rows(segments: [String], kind: Lookup, limit: Int?) -> [DictionaryLexeme] {
        guard let first = segments.first?.first, "abcdefghjklmnopqrstwxyz".contains(first) else { return [] }
        let count: Int
        if case .longer(let length) = kind { count = length } else { count = segments.count }
        let bucket = count <= 7 ? String(count) : "others"
        let table = "tbl_\(bucket)_\(first)"
        let key = segments.joined(separator: "'")
        let values: [DictionaryLexeme]
        if let database {
            switch kind {
            case .exact: values = database.rows(table: table, condition: "key=?", values: [key], limit: limit)
            case .prefix:
                // A nonterminal initial is a wildcard, so it belongs to the initials cascade.
                guard segments.dropLast().allSatisfy({ $0.count > 1 }) else { return [] }
                values = database.rows(table: table, condition: "key>=? AND key<?", values: [key, key + "{"], limit: limit)
            case .initials:
                let initials = segments.compactMap(\.first).map(String.init).joined()
                values = database.rows(table: table, condition: "jp=?", values: [initials], limit: limit.map { max(128, $0 * 16) })
                    .filter { Self.matchesInitials($0.reading, typed: segments) }
            case .longer:
                let prefix = key + "'"
                values = database.rows(table: table, condition: "key>=? AND key<?", values: [prefix, prefix + "{"], limit: limit)
            }
        } else {
            switch kind {
            case .exact: values = exact[key] ?? []
            case .prefix:
                guard segments.dropLast().allSatisfy({ $0.count > 1 }) else { return [] }
                values = entries.filter {
                    (count <= 7 ? $0.reading.count == count : $0.reading.count > 7) && $0.key.hasPrefix(key)
                }
            case .initials: values = entries.filter { Self.matchesInitials($0.reading, typed: segments) }
            case .longer:
                values = entries.filter {
                    (count <= 7 ? $0.reading.count == count : $0.reading.count > 7) && $0.key.hasPrefix(key + "'")
                }
            }
        }
        let ordered = ranked(values)
        return limit.map { Array(ordered.prefix($0)) } ?? ordered
    }

    private func ranked(_ values: [DictionaryLexeme]) -> [DictionaryLexeme] {
        values.sorted { $0.weight == $1.weight ? $0.ordinal < $1.ordinal : $0.weight > $1.weight }
    }

    private func uniqueWords(_ values: [DictionaryLexeme]) -> [DictionaryLexeme] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.text).inserted }
    }

    private static func matchesInitials(_ actual: [String], typed: [String]) -> Bool {
        guard actual.count == typed.count else { return false }
        return zip(actual, typed).allSatisfy { full, part in
            if part.count == 1 { return full.first == part.first }
            if ["zh", "ch", "sh"].contains(part) { return full.hasPrefix(part) }
            return full == part
        }
    }
}
