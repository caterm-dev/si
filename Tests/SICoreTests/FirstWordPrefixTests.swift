import Foundation
import Testing
@testable import SICore

struct FirstWordPrefixTests {
    @Test func packagedCharacterHomophonesSurviveBothSearchStagesAndPresentation() {
        let expected = Set(ChineseLexicon.standard.exactMatches(["she"]).filter { $0.text.count == 1 }.map(\.text))
        #expect(expected.count > 24)
        for input in ["she", "sheguofennudehai", "she'guo'fen'nu'de'hai"] {
            for preview in [false, true] {
                let generated = PinyinDecoder.standard.compositionCandidates(for: input, languages: [.simplifiedChinese], preview: preview)
                let visible = CandidateShortlist.candidates(from: generated)
                #expect(expected.isSubset(of: Set(visible.filter { $0.lexicalTokenCount == 1 }.map(\.text))))
            }
        }
    }

    @Test func completeSyllableKeepsEveryCharacterInPreviewFullAndTheWindow() {
        let characters = (0..<80).map { String(UnicodeScalar(0x4E00 + $0)!) }
        let decoder = PinyinDecoder(entries: characters.map { PinyinLexiconEntry(syllables: ["bi"], text: $0) }
            + [PinyinLexiconEntry(syllables: ["ge"], text: "个")])
        for input in ["bi", "bige", "bi'ge"] {
            for preview in [false, true] {
                let generated = decoder.compositionCandidates(for: input, languages: [.simplifiedChinese], preview: preview)
                let visible = CandidateShortlist.candidates(from: generated)
                let selected = visible.filter { characters.contains($0.text) }
                #expect(Set(selected.map(\.text)) == Set(characters))
                #expect(selected.count == characters.count)
                #expect(selected.allSatisfy { $0.lexicalTokenCount == 1 && !$0.hasCompletion })
                if input != "bi" { #expect(selected.allSatisfy { $0.consumedInputCount == (input == "bige" ? 2 : 3) }) }
                #expect(visible == CandidateShortlist.candidates(from: generated))
            }
        }
    }

    @Test func fourConstructedChoicesLeaveTheRemainingSlotsForRankedWords() {
        let sentence = InputCandidate(text: "完整句子", language: .simplifiedChinese, score: 100)
        let fragments = (0..<40).map {
            InputCandidate(text: "长片段\($0)", language: .simplifiedChinese,
                           score: 90 - $0, consumedInputCount: 9, lexicalTokenCount: 3)
        }
        let words = (0..<20).map {
            InputCandidate(text: "词\($0)", language: .simplifiedChinese,
                           score: -$0, consumedInputCount: 3, lexicalTokenCount: 1)
        }
        let english = InputCandidate(text: "word", language: .english, score: -100, lexicalTokenCount: 1)
        let mixed = InputCandidate(text: "中word", language: .simplifiedChinese, score: -101, isMixed: true)
        let literal = InputCandidate(text: "synthetic", language: nil, score: 0)
        let engine = [sentence] + fragments + words + [english, mixed, literal]
        let shortlist = CandidateShortlist.candidates(from: engine)
        #expect(shortlist.count == words.count + 6 && shortlist.count <= CandidateShortlist.ordinaryCandidateLimit)
        #expect(shortlist.first == sentence && shortlist.last == literal)
        #expect(words.prefix(12).allSatisfy(shortlist.contains))
        #expect(shortlist.contains(english) && shortlist.contains(mixed))
        #expect(shortlist.prefix(4).allSatisfy { $0.lexicalTokenCount != 1 })
        #expect(shortlist.dropFirst(4).dropLast().allSatisfy { $0.lexicalTokenCount == 1 })
        #expect(shortlist.filter(\.isLexicalPrefix) == Array(words.prefix(20)))
        #expect(shortlist == CandidateShortlist.candidates(from: engine))

        // Sentence alternatives share the four-choice cap with mixed fragments.
        let readings = (0..<12).map {
            InputCandidate(text: "完整句\($0)", language: .simplifiedChinese, score: 100 - $0)
                .withChineseSentenceOrigin()
        }
        let history = InputCandidate(text: "历史", language: .simplifiedChinese, score: 1,
                                     isHistory: true, historyInput: "synthetic")
        let crowded = CandidateShortlist.candidates(from: readings + fragments + words + [english, mixed, history, literal])
        #expect(crowded.count == CandidateShortlist.ordinaryCandidateLimit && crowded.last == literal)
        #expect(crowded.filter { $0.isChineseSentence || $0.isMixed }.count == 4)
        #expect(crowded.contains(english) && crowded.contains(mixed) && crowded.contains(history))
        #expect(words.allSatisfy(crowded.contains))
    }

    @Test func lexicalHomophonesHaveTheirOwnBoundedPoolAndHonorConsumedSpellingLearning() throws {
        let characters = (0..<30).map { String(UnicodeScalar(0x4E00 + $0)!) + "词" }
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
