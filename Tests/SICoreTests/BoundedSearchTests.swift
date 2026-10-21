import Foundation
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
        var weights: [String: Double] = [:]
        for word in words { weights[word.text] = max(weights[word.text, default: 0], exp2(Double(word.score) / 10)) }
        let total = weights.keys.sorted().reduce(1.0) { $0 + weights[$1]! }
        // Enumerate all 6,561 paths independently, including canonical alias reading costs.
        var exhaustive: [(text: String, cost: Double)] = [("", 0)]
        for _ in 0..<4 {
            exhaustive = exhaustive.flatMap { path in
                words.map { word in
                    let language = path.text.isEmpty ? 1.0 : -log2(1 - RankingCalibration.switchProbability)
                    return (path.text + word.text, path.cost + log2(total) - Double(word.score) / 10 + language + log2(1.5))
                }
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
        var baseline: [InputCandidate]?
        for order in [words, Array(words.reversed()), Array(words.dropFirst(3)) + Array(words.prefix(3))] {
            let decoder = PinyinDecoder(entries: order.map { PinyinLexiconEntry(syllables: ["a"], text: $0.text, score: $0.score) })
            let candidates = decoder.candidates(for: "aaaa")
            // Logarithmic sums may differ by an ULP for mathematically tied permutations.
            // Verify exhaustive optimal costs, all strictly better paths, and insertion-order identity.
            #expect(candidates.count == expected.count)
            for (candidate, path) in zip(candidates, expected) { #expect(abs(candidate.rankingScore + path.cost) < 1e-10) }
            let threshold = expected.last!.cost
            for path in distinct.values where path.cost < threshold - 1e-10 {
                #expect(candidates.contains { $0.text == path.text })
            }
            if let baseline {
                #expect(candidates == baseline)
                #expect(candidates.map { Array($0.text.utf8) } == baseline.map { Array($0.text.utf8) })
            } else { baseline = candidates }
            #expect(Set(candidates.map(\.id)).count == candidates.count)
        }
    }
}
