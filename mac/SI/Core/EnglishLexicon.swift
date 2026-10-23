import Foundation

/// One immutable vocabulary shared by direct English lookup and mixed decoding.
/// Trie nodes refer to ranges of sorted entries, never copies of completion lists.
/// Database words are unique ASCII spellings sorted by their lowercase key.
enum EnglishLexicon {
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
        let length: Int
        let id: Int
        let weight: Int64
        let probability: Double
        let lexicalCost: Double
        private let truncationOffset: Double
        private let capitalizedText: String
        private let uppercaseText: String

        init(_ row: DictionaryLexeme, index: Int, totalWeight: Double) {
            let word = row.text
            text = word
            length = word.utf8.count
            id = index + 1
            weight = row.weight
            probability = Double(max(1, row.weight)) / totalWeight
            lexicalCost = CandidateScoring.wordCost(weight: row.weight)
            truncationOffset = WordPrefixChannel.cost(fullLength: length, typedLength: length)
            capitalizedText = word.prefix(1).uppercased() + word.dropFirst()
            uppercaseText = word.uppercased()
        }

        func cost(typedLength: Int) -> Double {
            CandidateScoring.initialLanguageCost + lexicalCost + channelCost(typedLength: typedLength)
        }

        func channelCost(typedLength: Int) -> Double { Double(length - typedLength) + truncationOffset }

        func text(for style: CaseStyle) -> String {
            switch style {
            case .original: text
            case .capitalized: capitalizedText
            case .uppercase: uppercaseText
            }
        }
    }

    private struct Node {
        let childMask: UInt32
        let childStart: Int32
        let terminal: Int32
        let lower: Int32
        let upper: Int32
        let bestStart: Int32
        let bestCount: Int32
    }

    private struct Trie {
        let nodes: [Node]
        let children: [Int32]
        let bestEntries: [Int32]

        init(entries: [Entry]) {
            let keys = entries.map { Array($0.text.lowercased().utf8) }
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
                nodes.append(Node(childMask: 0, childStart: 0, terminal: -1, lower: 0, upper: 0, bestStart: 0, bestCount: 0))
                let terminal = range.first.flatMap { keys[$0].count == depth ? Int32($0) : nil } ?? -1
                var start = range.lowerBound + (terminal >= 0 ? 1 : 0)
                var mask: UInt32 = 0
                var childNodes: [Int32] = []
                while start < range.upperBound {
                    let byte = keys[start][depth]
                    var end = start + 1
                    while end < range.upperBound && keys[end][depth] == byte { end += 1 }
                    mask |= UInt32(1) << (byte - 97)
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
                    if terminal >= 0 { best.append(terminal) }
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
                                   lower: Int32(range.lowerBound), upper: Int32(range.upperBound), bestStart: bestStart, bestCount: bestCount)
                return Int32(node)
            }

            _ = appendNode(entries.indices, depth: 0)
            self.nodes = nodes
            self.children = children
            self.bestEntries = bestEntries
        }

        func advance(_ node: Int, byte: UInt8) -> Int? {
            guard byte >= 97 && byte <= 122 else { return nil }
            let bit = UInt32(1) << (byte - 97)
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
        for row in rows {
            let key = row.text.lowercased()
            guard (1...64).contains(row.text.utf8.count),
                  row.text.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }),
                  row.reading == [key], row.weight >= 0, key > previous else { return ([], 1, CandidateScoring.wordCost(weight: 1)) }
            previous = key
        }
        let unknown = Double(max(1, database.unknownWeight))
        let total = rows.reduce(unknown) { $0 + Double(max(1, $1.weight)) }
        return (rows.enumerated().map { Entry($0.element, index: $0.offset, totalWeight: total) }, unknown / total, CandidateScoring.wordCost(weight: max(1, database.unknownWeight)))
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
            .filter { $0 != value.terminal }.map { entries[Int($0)] }
    }

    /// Mixed completion excludes the exact word; callers enforce its two-letter minimum.
    static func completions(at node: Int) -> ArraySlice<Entry> {
        let value = trie.nodes[node]
        return entries[(Int(value.lower) + (value.terminal >= 0 ? 1 : 0))..<Int(value.upper)]
    }
}
