import Testing
@testable import SICore

struct BoundedSearchTests {
    @Test func normalizationAcrossTokenBoundariesNeverRewritesCommittedBytes() throws {
        for (first, second, normalized) in [("a", "\u{301}", "á"), ("\u{1100}", "\u{1161}", "가")] {
            let entries = [PinyinLexiconEntry(syllables: ["wo"], text: first),
                           PinyinLexiconEntry(syllables: ["shi"], text: second)]
            let raw = try #require(PinyinDecoder(entries: entries).candidates(for: "woshi").first)
            #expect(raw.text == normalized)
            #expect(Array(raw.text.utf8) == Array((first + second).utf8))
            let direct = PinyinLexiconEntry(syllables: ["wo", "shi"], text: normalized)
            let deduplicated = PinyinDecoder(entries: entries + [direct]).candidates(for: "woshi")
            #expect(deduplicated.count == 1)
            #expect(Array(deduplicated[0].text.utf8) == Array(normalized.utf8))
        }
    }

    @Test func canonicalEquivalentsAcrossComparisonPathsDoNotConsumeExtraBeamSlots() {
        let words = ["豈", "\u{f900}", "é", "e\u{301}", "甲"]
        let decoder = PinyinDecoder(entries: words.map { PinyinLexiconEntry(syllables: ["a"], text: $0) })
        let candidates = decoder.candidates(for: "aa")
        let expected = Set(["豈", "é", "甲"].flatMap { first in ["豈", "é", "甲"].map { first + $0 } })
        #expect(candidates.count == 9)
        #expect(Set(candidates.map(\.text)) == expected)
        #expect(candidates.first?.text == "éé")
        #expect(Set(candidates.map(\.id)).count == candidates.count)
    }

    @Test func boundedResultsMatchExhaustiveSmallVocabularySearchInDifferentInsertionOrders() {
        let words: [(text: String, score: Int)] = [
            ("甲", 100), ("乙", 99), ("丙", 98), ("é", 97), ("e\u{301}", 96),
            ("女", 95), ("👩🏽‍💻", 94), ("豈", 93), ("\u{f900}", 94),
        ]
        // Enumerate all 6,561 complete paths, independently of the bounded decoder.
        var exhaustive: [(text: String, cost: Double)] = [("", 0)]
        for _ in 0..<4 {
            exhaustive = exhaustive.flatMap { path in
                words.map { (path.text + $0.text, path.cost + 8 + Double(100 - $0.score) / 4) }
            }
        }
        var distinct: [String: (text: String, cost: Double)] = [:]
        for path in exhaustive {
            if let previous = distinct[path.text], previous.cost <= path.cost { continue }
            distinct[path.text] = path
        }
        let expected = distinct.values.sorted {
            $0.cost != $1.cost ? $0.cost < $1.cost : $0.text < $1.text
        }.prefix(12)
        for order in [words, Array(words.reversed()), Array(words.dropFirst(3)) + Array(words.prefix(3))] {
            let decoder = PinyinDecoder(entries: order.map { PinyinLexiconEntry(syllables: ["a"], text: $0.text, score: $0.score) })
            let candidates = decoder.candidates(for: "aaaa")
            #expect(candidates.map(\.text) == expected.map(\.text))
            #expect(candidates.map { Array($0.text.utf8) } == expected.map { Array($0.text.utf8) })
            #expect(candidates.map(\.rankingScore) == expected.map { 94 - $0.cost / 10 })
            #expect(Set(candidates.map(\.id)).count == candidates.count)
        }
    }
}
