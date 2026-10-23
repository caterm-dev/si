import Foundation
import Testing
@testable import SICore

struct FirstWordPrefixTests {
    @Test func lexicalHomophonesHaveTheirOwnBoundedPoolAndHonorConsumedSpellingLearning() throws {
        let characters = (0..<30).map { String(UnicodeScalar(0x4E00 + $0)!) }
        let decoder = PinyinDecoder(entries: characters.map { PinyinLexiconEntry(syllables: ["bi"], text: $0) }
            + [PinyinLexiconEntry(syllables: ["ge"], text: "个")])
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let base = decoder.compositionCandidates(for: "bige", languages: [.simplifiedChinese], now: now)
        let prefixes = base.filter { $0.isLexicalPrefix && $0.consumedInputCount == 2 }
        #expect(prefixes.count == 24)
        #expect(Set(prefixes.map(\.id)).count == 24)
        #expect(base == decoder.compositionCandidates(for: "bige", languages: [.simplifiedChinese], now: now))
        let targetText = try #require(characters.last)
        let target = InputCandidate(text: targetText, language: .simplifiedChinese, score: 0)
        #expect(!prefixes.contains { $0.text == targetText })
        var learning = LearningProfile()
        for _ in 0..<8 { learning.record(InputCommit(input: "bi", candidate: target, reason: .explicitSelection), now: now) }
        let learned = decoder.compositionCandidates(for: "bige", languages: [.simplifiedChinese], learning: learning, now: now)
        #expect(learned.contains { $0.text == targetText && $0.isLexicalPrefix && $0.consumedInputCount == 2 })
        learning.removeAll()
        #expect(decoder.compositionCandidates(for: "bige", languages: [.simplifiedChinese], learning: learning, now: now) == base)
    }

    @Test func aHigherScoringComposedDerivationRetainsSingleWordEvidenceWithoutChangingItsScore() throws {
        let decoder = PinyinDecoder(entries: [
            PinyinLexiconEntry(syllables: ["wo"], text: "我", upstreamWeight: 1_000_000),
            PinyinLexiconEntry(syllables: ["shi"], text: "是", upstreamWeight: 100_000),
            PinyinLexiconEntry(syllables: ["wo", "shi"], text: "我是", score: 0),
            PinyinLexiconEntry(syllables: ["b"], text: "吧"),
        ])
        let whole = try #require(decoder.candidates(for: "woshi").first { $0.text == "我是" })
        let prefix = try #require(decoder.compositionCandidates(for: "woshib", languages: [.simplifiedChinese])
            .first { $0.text == "我是" && $0.consumedInputCount == 5 })
        #expect(whole.lexicalTokenCount == 1 && prefix.isLexicalPrefix)
        #expect(abs(prefix.rankingScore - whole.rankingScore) < 1e-12)
        #expect(prefix.id == "prefix5:zh-Hans:我是")
    }
}
