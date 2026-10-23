import Foundation
import Testing
@testable import SICore

struct SpellingEvidenceTests {
    @Test func chineseSpellingIsNormalizedPerSyllableAndIndependentOfWordSegmentation() {
        for length in 1...64 {
            let mass = (0...length).reduce(0.0) {
                $0 + exp2(-PinyinSpellingChannel.cost(length: length, typedLength: $1))
            }
            #expect(abs(mass - 1) < 1e-12)
            #expect(PinyinSpellingChannel.cost(length: length, typedLength: length)
                    < PinyinSpellingChannel.cost(length: length, typedLength: length - 1))
            #expect(abs(PinyinSpellingChannel.cost(length: length, typedLength: length - 1)
                - PinyinSpellingChannel.cost(length: length, typedLength: length) - 5) < 1e-12)
        }
        let whole = PinyinSpellingChannel.cost(syllables: ["di", "er", "ye"], typedLength: 6)
        let split = ["di", "er", "ye"].reduce(0.0) {
            $0 + PinyinSpellingChannel.cost(syllables: [$1], typedLength: $1.count)
        }
        #expect(whole == split)
        #expect(whole < PinyinSpellingChannel.cost(syllables: ["di", "er", "yue", "er"], typedLength: 6))
        #expect(PinyinSpellingChannel.cost(syllables: ["ni", "hao"], typedLength: 5)
                < PinyinSpellingChannel.cost(syllables: ["ni", "hao"], typedLength: 4))
    }

    @Test func initialsCannotExhaustFullSpellingPathsBeforeFinalOrPrefixSelection() throws {
        let alternatives = (0..<24).map {
            PinyinLexiconEntry(syllables: ["er", "yue", "er"],
                               text: String(UnicodeScalar(0x5000 + $0)!), upstreamWeight: 1_000_000)
        }
        let decoder = PinyinDecoder(entries: alternatives + [
            PinyinLexiconEntry(syllables: ["di"], text: "第", upstreamWeight: 100),
            PinyinLexiconEntry(syllables: ["er"], text: "二", upstreamWeight: 10),
            PinyinLexiconEntry(syllables: ["ye"], text: "页", upstreamWeight: 1),
            PinyinLexiconEntry(syllables: ["ma"], text: "吗", upstreamWeight: 10),
        ])
        for input in ["dierye", "di'er'ye", "dieryema"] {
            let expected = input.hasSuffix("ma") ? "第二页吗" : "第二页"
            let values = decoder.compositionCandidates(for: input, languages: [.simplifiedChinese])
            let full = try #require(values.first { $0.text == expected && !$0.isPartial })
            #expect(!full.hasCompletion)
            #expect(values.contains { $0.text == "第" + alternatives[0].text + (input.hasSuffix("ma") ? "吗" : "") })
        }
    }

    @Test func aLearnedConstructedAbbreviationKeepsItsPersonalizedSearchLane() throws {
        let words = (0..<20).map {
            PinyinLexiconEntry(syllables: ["ni", "hao"], text: "甲" + String(UnicodeScalar(0x5000 + $0)!),
                               score: 100 - $0)
        }
        let decoder = PinyinDecoder(entries: [PinyinLexiconEntry(syllables: ["wo"], text: "我")] + words)
        let text = "我" + words.last!.text
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(!decoder.candidates(for: "wonh").contains { $0.text == text })
        var learning = LearningProfile()
        let target = InputCandidate(text: text, language: .simplifiedChinese, score: 0)
        for _ in 0..<8 { learning.record(InputCommit(input: "wonh", candidate: target, reason: .explicitSelection), now: now) }
        let values = decoder.compositionCandidates(for: "wonh", languages: [.simplifiedChinese], learning: learning, now: now)
        #expect(values.first?.text == text)
        #expect(!values.first!.isPartial)
        learning.removeAll()
        #expect(!decoder.compositionCandidates(for: "wonh", languages: [.simplifiedChinese], learning: learning, now: now)
            .contains { $0.text == text })
    }

    @Test func terminalCompactionKeepsGeneralAndProtectedTopSetsAcrossLargeBatches() {
        let abbreviated = (0..<1_024).map {
            PinyinLexiconEntry(syllables: ["er", "yue", "er"],
                               text: "甲乙" + String(UnicodeScalar(0x5000 + $0)!), upstreamWeight: 1_000_000)
        }
        let full = (0..<3).map {
            PinyinLexiconEntry(syllables: ["er", "ye"],
                               text: "丙" + String(UnicodeScalar(0x4E10 + $0)!), upstreamWeight: 1)
        }
        let prefix = PinyinLexiconEntry(syllables: ["wo"], text: "我", upstreamWeight: 1_000_000)
        var baseline: [InputCandidate]?
        for words in [full + abbreviated, abbreviated + full, Array((full + abbreviated).reversed())] {
            let values = PinyinDecoder(entries: [prefix] + words).candidates(for: "woerye")
            // Final completions have their own independent state and may add results.
            let complete = values.filter { !$0.hasCompletion }
            #expect(complete.count == 14)
            #expect(complete.prefix(12).allSatisfy { $0.text.hasPrefix("我甲乙") })
            #expect(complete.filter { $0.text.hasPrefix("我丙") }.map(\.text) == full.prefix(2).map { "我" + $0.text })
            if let baseline { #expect(values == baseline) } else { baseline = values }
        }
    }
}
