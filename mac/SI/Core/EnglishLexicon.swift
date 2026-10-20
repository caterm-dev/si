/// One immutable vocabulary shared by direct English lookup and mixed decoding.
/// Trie nodes refer to ranges of sorted entries, never copies of completion lists.
/// Generated words are unique ASCII spellings sorted by their lowercase key.
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
        let completionScore: Int
        let completionCost: Double
        private let capitalizedText: String
        private let uppercaseText: String

        init(_ word: String) {
            text = word
            length = word.utf8.count
            completionScore = EnglishLexiconData.completionScores[word.lowercased()] ?? 75
            completionCost = 24 + Double(85 - completionScore) / 4
            capitalizedText = word.prefix(1).uppercased() + word.dropFirst()
            uppercaseText = word.uppercased()
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
        let childMask: UInt32
        let childStart: Int32
        let terminal: Int32
        let lower: Int32
        let upper: Int32
    }

    private struct Trie {
        let nodes: [Node]
        let children: [Int32]

        init(entries: [Entry]) {
            let keys = entries.map { Array($0.text.lowercased().utf8) }
            var nodes: [Node] = []
            var children: [Int32] = []
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
                nodes.append(Node(childMask: 0, childStart: 0, terminal: -1, lower: 0, upper: 0))
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
                let childStart = children.count
                children.append(contentsOf: childNodes)
                nodes[node] = Node(childMask: mask, childStart: Int32(childStart), terminal: terminal,
                                   lower: Int32(range.lowerBound), upper: Int32(range.upperBound))
                return Int32(node)
            }

            _ = appendNode(entries.indices, depth: 0)
            self.nodes = nodes
            self.children = children
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

    static let words = EnglishLexiconData.words
    static let entries = words.map(Entry.init)
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

    /// Mixed completion excludes the exact word; callers enforce its two-letter minimum.
    static func completions(at node: Int) -> ArraySlice<Entry> {
        let value = trie.nodes[node]
        return entries[(Int(value.lower) + (value.terminal >= 0 ? 1 : 0))..<Int(value.upper)]
    }
}
