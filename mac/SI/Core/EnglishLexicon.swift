import Foundation

/// One immutable vocabulary shared by direct English lookup and mixed decoding.
/// Trie nodes refer to ranges of sorted entries, never copies of completion lists.
/// Entries are sorted by typing key, then descending weight and canonical row ID.
enum EnglishLexicon {
    /// Literal domain keys retain dots, hyphens and digits. Standalone suffixes fail.
    static func domainReading(for text: String) -> String? {
        guard text.utf8.allSatisfy({ $0 < 128 }) else { return nil }
        let key = text.lowercased()
        guard key.utf8.count <= 253 else { return nil }
        let labels = key.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, let suffix = labels.last, (2...63).contains(suffix.utf8.count),
              suffix.utf8.allSatisfy({ (97...122).contains($0) }) else { return nil }
        for label in labels {
            let bytes = Array(label.utf8)
            guard (1...63).contains(bytes.count), bytes.first != 45, bytes.last != 45,
                  bytes.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }) else { return nil }
        }
        return key
    }

    /// Matches the offline CSV compiler; punctuation stays in the committed text.
    static func reading(for text: String) -> String? {
        let digits = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
        guard !text.isEmpty, text == text.trimmingCharacters(in: .whitespaces),
              text.utf8.allSatisfy({ (32...126).contains($0) }),
              text.utf8.contains(where: { (65...90).contains($0) || (97...122).contains($0) }) else { return nil }
        if let domain = domainReading(for: text) { return domain }
        var key = ""
        for byte in text.utf8 {
            if (65...90).contains(byte) { key.append(Character(UnicodeScalar(byte + 32))) }
            else if (97...122).contains(byte) { key.append(Character(UnicodeScalar(byte))) }
            else if (48...57).contains(byte) { key += digits[Int(byte - 48)] }
        }
        return (1...64).contains(key.utf8.count) ? key : nil
    }

    enum CaseStyle {
        case original, capitalized, uppercase

        init(input: String) {
            if input == input.uppercased() { self = .uppercase }
            else if input.first?.isUppercase == true { self = .capitalized }
            else { self = .original }
        }
    }

    struct Entry {
        let text: String
        let key: String
        let length: Int
        let id: Int
        let weight: Int64
        let probability: Double
        let lexicalCost: Double
        private let capitalizedText: String
        private let uppercaseText: String

        init(_ row: DictionaryLexeme, index: Int, totalWeight: Double) {
            let word = row.text
            text = word
            key = row.key
            length = row.key.utf8.count
            id = index + 1
            weight = row.weight
            probability = Double(max(1, row.weight)) / totalWeight
            lexicalCost = CandidateScoring.wordCost(weight: row.weight)
            capitalizedText = word.prefix(1).uppercased() + word.dropFirst()
            uppercaseText = word.uppercased()
        }

        func cost(typedLength: Int) -> Double {
            CandidateScoring.initialLanguageCost + lexicalCost + channelCost(typedLength: typedLength)
        }

        func channelCost(typedLength: Int) -> Double {
            WordPrefixChannel.cost(fullLength: length, typedLength: typedLength)
        }

        func text(for style: CaseStyle) -> String {
            switch style {
            case .original: text
            case .capitalized: capitalizedText
            case .uppercase: uppercaseText
            }
        }
    }

    private struct Node {
        let childMask: UInt64
        let childStart: Int32
        let terminal: Int32
        let terminalCount: Int32
        let lower: Int32
        let upper: Int32
        let bestStart: Int32
        let bestCount: Int32
    }

    private struct Trie {
        let nodes: [Node]
        let children: [Int32]
        let bestEntries: [Int32]

        // Bit order follows ASCII key order, matching the stored child array.
        private static func symbolIndex(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 45: 0
            case 46: 1
            case 48...57: byte - 48 + 2
            case 97...122: byte - 97 + 12
            default: nil
            }
        }

        init(entries: [Entry]) {
            let keys = entries.map { Array($0.key.utf8) }
            var nodes: [Node] = []
            var children: [Int32] = []
            var bestEntries: [Int32] = []
            // Count shared prefixes before allocation, avoiding oversized retained buffers.
            var nodeCount = 1
            var previous: [UInt8] = []
            for key in keys {
                let common = zip(previous, key).prefix { $0 == $1 }.count
                nodeCount += key.count - common
                previous = key
            }
            precondition(nodeCount <= Int(Int32.max) && entries.count <= Int(Int32.max))
            nodes.reserveCapacity(nodeCount)
            children.reserveCapacity(nodeCount - 1)

            func appendNode(_ range: Range<Int>, depth: Int) -> Int32 {
                let node = nodes.count
                nodes.append(Node(childMask: 0, childStart: 0, terminal: -1, terminalCount: 0,
                                  lower: 0, upper: 0, bestStart: 0, bestCount: 0))
                let terminals = range.prefix { keys[$0].count == depth }
                let terminal = terminals.min {
                    let a = entries[$0], b = entries[$1]
                    return a.weight == b.weight ? $0 < $1 : a.weight > b.weight
                }.map(Int32.init) ?? -1
                var start = range.lowerBound + terminals.count
                var mask: UInt64 = 0
                var childNodes: [Int32] = []
                while start < range.upperBound {
                    let byte = keys[start][depth]
                    var end = start + 1
                    while end < range.upperBound && keys[end][depth] == byte { end += 1 }
                    mask |= UInt64(1) << Self.symbolIndex(byte)!
                    childNodes.append(appendNode(start..<end, depth: depth + 1))
                    start = end
                }
                let bestStart: Int32
                let bestCount: Int32
                if terminal < 0, childNodes.count == 1 {
                    // Single-child chains share their immutable top-eight slice.
                    let child = nodes[Int(childNodes[0])]
                    bestStart = child.bestStart
                    bestCount = child.bestCount
                } else {
                    var best = childNodes.flatMap { childID -> [Int32] in
                        let child = nodes[Int(childID)]
                        return Array(bestEntries[Int(child.bestStart)..<Int(child.bestStart + child.bestCount)])
                    }
                    best.append(contentsOf: terminals.map(Int32.init))
                    best.sort {
                        let a = entries[Int($0)], b = entries[Int($1)]
                        let ac = a.cost(typedLength: max(1, depth))
                        let bc = b.cost(typedLength: max(1, depth))
                        return ac == bc ? $0 < $1 : ac < bc
                    }
                    bestStart = Int32(bestEntries.count)
                    bestCount = Int32(min(8, best.count))
                    bestEntries.append(contentsOf: best.prefix(8))
                }
                let childStart = children.count
                children.append(contentsOf: childNodes)
                nodes[node] = Node(childMask: mask, childStart: Int32(childStart), terminal: terminal,
                                   terminalCount: Int32(terminals.count),
                                   lower: Int32(range.lowerBound), upper: Int32(range.upperBound), bestStart: bestStart, bestCount: bestCount)
                return Int32(node)
            }

            _ = appendNode(entries.indices, depth: 0)
            self.nodes = nodes
            self.children = children
            self.bestEntries = bestEntries
        }

        func advance(_ node: Int, byte: UInt8) -> Int? {
            guard let symbol = Self.symbolIndex(byte) else { return nil }
            let bit = UInt64(1) << symbol
            let value = nodes[node]
            guard value.childMask & bit != 0 else { return nil }
            let offset = (value.childMask & (bit - 1)).nonzeroBitCount
            return Int(children[Int(value.childStart) + offset])
        }
    }

    private static let loaded: (entries: [Entry], unknownProbability: Double, unknownCost: Double) = {
        let database = LexiconDatabase(url:
            DictionaryResources.url("si-english", extension: "sqlite", languageDirectory: "English"))
        let rows = database.allEntries()
        // Reject a corrupt/incompatible English resource as a whole. Literal fallback
        // and the independent Chinese dictionary remain available.
        var previous = ""
        var previousText = ""
        for row in rows {
            guard let key = reading(for: row.text),
                  row.reading == [key], row.weight >= 0,
                  key > previous || (key == previous && row.text > previousText) else {
                return ([], 1, CandidateScoring.wordCost(weight: 1))
            }
            previous = key
            previousText = row.text
        }
        let unknown = Double(max(1, database.unknownWeight))
        let total = rows.reduce(unknown) { $0 + Double(max(1, $1.weight)) }
        // Equal-key variants share a spelling cost; retain their weight order.
        let entries = rows.enumerated().map { Entry($0.element, index: $0.offset, totalWeight: total) }.sorted {
            if $0.key != $1.key { return $0.key < $1.key }
            return $0.weight == $1.weight ? $0.id < $1.id : $0.weight > $1.weight
        }
        return (entries, unknown / total, CandidateScoring.wordCost(weight: max(1, database.unknownWeight)))
    }()
    static let entries = loaded.entries
    static let words = entries.map(\.text)
    static let unknownProbability = loaded.unknownProbability
    static let unknownCost = loaded.unknownCost
    static let maximumLength = entries.map(\.length).max() ?? 0
    private static let trie = Trie(entries: entries)

    static func prepare() {
        _ = trie
        _ = maximumLength
    }

    /// A cursor starts at the root (zero); a failed transition stays failed for that span.
    static func advance(_ node: Int, byte: UInt8) -> Int? { trie.advance(node, byte: byte) }

    static func exactMatch(at node: Int) -> Entry? {
        let terminal = trie.nodes[node].terminal
        return terminal >= 0 ? entries[Int(terminal)] : nil
    }

    static func exactMatches(at node: Int) -> ArraySlice<Entry> {
        let value = trie.nodes[node]
        return entries[Int(value.lower)..<Int(value.lower + value.terminalCount)]
    }

    static func matches(for key: String) -> ArraySlice<Entry> {
        guard !key.isEmpty else { return entries[0..<0] }
        var node = 0
        for byte in key.utf8 {
            guard let next = advance(node, byte: byte) else { return entries[0..<0] }
            node = next
        }
        let value = trie.nodes[node]
        return entries[Int(value.lower)..<Int(value.upper)]
    }

    static func previewMatches(for key: String) -> [Entry] {
        guard !key.isEmpty else { return [] }
        var node = 0
        for byte in key.utf8 {
            guard let next = advance(node, byte: byte) else { return [] }
            node = next
        }
        let value = trie.nodes[node]
        return trie.bestEntries[Int(value.bestStart)..<Int(value.bestStart + value.bestCount)].map { entries[Int($0)] }
    }

    static func previewCompletions(at node: Int) -> [Entry] {
        let value = trie.nodes[node]
        return trie.bestEntries[Int(value.bestStart)..<Int(value.bestStart + value.bestCount)]
            .filter { $0 >= value.lower + value.terminalCount }.map { entries[Int($0)] }
    }

    /// Mixed completion excludes the exact word; callers enforce its two-letter minimum.
    static func completions(at node: Int) -> ArraySlice<Entry> {
        let value = trie.nodes[node]
        return entries[Int(value.lower + value.terminalCount)..<Int(value.upper)]
    }
}
