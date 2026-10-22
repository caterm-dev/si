/// Bounded correction-mode segmentation from MSIME's pinyin/segment.rs (GPL-3.0-only).
/// This is the fixed spelling-alias channel, not an unbounded edit-distance search.
enum ChineseSpellingAliases {
    private struct Piece {
        let value: String
        let end: Int
        let length: Int
        let rank: Int
        let corrected: Bool
    }

    private static let aliases: [String: [String]] = {
        var result: [String: [String]] = [:]
        func add(_ typed: String, _ reading: String) {
            if !(result[typed] ?? []).contains(reading) { result[typed, default: []].append(reading) }
        }
        func suffix(_ canonical: String, _ typed: String) {
            for syllable in ChineseSyllables.complete.sorted() where syllable.hasSuffix(canonical) {
                add(String(syllable.dropLast(canonical.count)) + typed, syllable)
            }
        }
        suffix("iang", "aing")
        suffix("uang", "aung")
        suffix("ian", "ain")
        suffix("uan", "aun")
        suffix("iao", "aio")
        suffix("ing", "ihng")
        suffix("ang", "agn")
        suffix("eng", "egn")
        add("egn", "eng")
        add("jv", "ju")
        suffix("ong", "on")
        suffix("hang", "ahng")
        suffix("ang", "ahng")
        suffix("heng", "ehng")
        suffix("eng", "ehng")
        return result
    }()

    static func readings(_ input: PinyinInput) -> [ChineseReading] {
        var merged: [[Piece]] = [[]]
        var start = 0
        for end in input.separators.union([input.letters.count]).sorted() where end > start {
            let tails = pieceReadings(Array(input.letters[start..<end]), sourceStart: start)
            guard !tails.isEmpty else { return [] }
            var product: [[Piece]] = []
            for head in merged {
                for tail in tails {
                    product.append(head + tail)
                    if product.count == 32 { break }
                }
                if product.count == 32 { break }
            }
            merged = product
            start = end
        }
        return merged.map { path in
            ChineseReading(syllables: path.map(\.value), offsets: [0] + path.map(\.end),
                           isCorrected: path.contains(where: \.corrected))
        }
    }

    private static func pieceReadings(_ letters: [Character], sourceStart: Int) -> [[Piece]] {
        let count = letters.count
        let maximum = max(6, aliases.keys.map(\.count).max() ?? 0)
        var paths = Array(repeating: [[Piece]](), count: count + 1)
        paths[count] = [[]]
        for start in (0..<count).reversed() {
            var candidates: [[Piece]] = []
            var minimum = Int.max
            for end in (start + 1...min(count, start + maximum)).reversed() {
                guard let suffix = paths[end].first else { continue }
                let typed = String(letters[start..<end])
                let readings = aliases[typed] ?? (ChineseSyllables.complete.contains(typed) ? [typed] : [])
                guard !readings.isEmpty else { continue }
                let length = suffix.count + 1
                if length < minimum { candidates.removeAll(keepingCapacity: true); minimum = length }
                guard length == minimum else { continue }
                for (rank, reading) in readings.enumerated() {
                    let piece = Piece(value: reading, end: sourceStart + end, length: end - start,
                                      rank: rank, corrected: reading != typed)
                    for suffix in paths[end] { candidates.append([piece] + suffix) }
                }
            }
            candidates.sort {
                let a = $0.map(\.length), b = $1.map(\.length)
                if a != b { return a.lexicographicallyPrecedes(b) }
                let x = $0.map(\.rank), y = $1.map(\.rank)
                if x != y { return x.lexicographicallyPrecedes(y) }
                return $0.map(\.value).lexicographicallyPrecedes($1.map(\.value))
            }
            var seen = Set<String>()
            paths[start] = Array(candidates.filter { seen.insert($0.map(\.value).joined(separator: "'")).inserted }.prefix(32))
        }
        return paths[0]
    }
}
