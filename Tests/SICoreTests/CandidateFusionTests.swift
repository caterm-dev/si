import Foundation
import Testing
@testable import SICore

struct CandidateFusionTests {
    @Test func aiOrderIgnoresEngineMarginsAndPositiveWeightScale() throws {
        let engineChoice = InputCandidate(text: "我们开慧", language: .simplifiedChinese, score: 1_000)
        let aiChoice = InputCandidate(text: "我们开会", language: .simplifiedChinese, score: -1_000)
        let base = [engineChoice, aiChoice]
        let probabilities = [engineChoice.id: -12.1, aiChoice.id: -12.0]
        for weight in [0.1, 1, 2] {
            let ranking = CandidateFusion(candidates: base, logProbabilities: probabilities, weight: weight)
            #expect(ranking.candidates.map(\.id) == [aiChoice.id, engineChoice.id])
            let score = try #require(ranking.scores[aiChoice.id])
            #expect(abs(score - weight * -12 / 4 / log(2)) < 1e-10)
        }
        #expect(CandidateFusion(candidates: base, logProbabilities: probabilities, weight: 0).candidates == base)
        let tied = CandidateFusion(candidates: base,
            logProbabilities: [engineChoice.id: -12, aiChoice.id: -12], weight: 1)
        #expect(tied.candidates == base)
        // Both used to receive zero bounded reward, losing unequal model evidence.
        let low = CandidateFusion(candidates: base,
            logProbabilities: [engineChoice.id: -101, aiChoice.id: -100], weight: 1)
        #expect(low.candidates.first?.id == aiChoice.id)
    }

    @Test func languageAwareFusionPreservesBaseOrderAndExactLiteralBytes() {
        let a = InputCandidate(text: "会", language: .simplifiedChinese, score: 100)
        let b = InputCandidate(text: "慧", language: .simplifiedChinese, score: 102)
        let english = InputCandidate(text: "hi", language: .english, score: 98)
        let literal = InputCandidate(text: "KaiHui", language: nil, score: 0)
        let base = [b, a, english, literal]
        let fusion = CandidateFusion(candidates: base,
            logProbabilities: [a.id: -1, b.id: -10, english.id: -2], weight: 1)
        #expect(base.first?.id == b.id)
        #expect(fusion.candidates.first?.id == a.id)
        #expect(fusion.candidates.last?.text.utf8.elementsEqual("KaiHui".utf8) == true)
        #expect(Set(fusion.candidates.map(\.id)) == Set(base.map(\.id)))
        #expect(CandidateFusion(candidates: base, logProbabilities: [:], weight: 0).candidates == base)
    }

    @Test func unscoredPathsFollowAIChoicesInTheirOriginalOrder() {
        let prefix = InputCandidate(text: "词", language: .simplifiedChinese, score: 50, consumedInputCount: 2)
        let other = InputCandidate(text: "此处", language: .simplifiedChinese, score: 55)
        let alone = CandidateFusion(candidates: [prefix], logProbabilities: [prefix.id: -3], weight: 1)
        let longer = CandidateFusion(candidates: [other, prefix],
            logProbabilities: [prefix.id: -3, other.id: -1], weight: 1)
        #expect(alone.scores[prefix.id] == longer.scores[prefix.id])
        // Prefix/whole LM calibration is intentionally excluded from this preview.
        #expect(alone.scores[prefix.id] == nil)
        #expect(longer.candidates.map(\.id) == [other.id, prefix.id])
        let unscored = InputCandidate(text: "未评分", language: .simplifiedChinese, score: 1_000)
        let retained = CandidateFusion(candidates: [unscored, prefix, other],
            logProbabilities: [other.id: -1], weight: 1)
        #expect(retained.candidates.map(\.id) == [other.id, unscored.id, prefix.id])
    }

    @Test func explicitPinsAndRememberedChoicesRetainPriorityAndExcludedPathsHaveNoAIScore() {
        let pin = InputCandidate(text: "个人", language: .simplifiedChinese, score: 10, isUserPhrase: true, isPreferred: true)
        let remembered = InputCandidate(text: "纠正", language: .simplifiedChinese, score: 20)
            .withPresentationScore(25, remembered: true)
        let regular = InputCandidate(text: "普通", language: .simplifiedChinese, score: 100)
        let verbatim = InputCandidate(text: "代码X", language: .simplifiedChinese, score: 90, hasLiteralSegments: true)
        let fusion = CandidateFusion(candidates: [pin, remembered, regular, verbatim],
            logProbabilities: [pin.id: -1, remembered.id: -1, regular.id: -1, verbatim.id: -1], weight: 2)
        #expect(fusion.candidates.prefix(2).map(\.id) == [pin.id, remembered.id])
        #expect(fusion.scores[pin.id] == nil && fusion.scores[verbatim.id] == nil)
        #expect(fusion.scores[remembered.id] != nil)
        let invalid = CandidateFusion(candidates: [regular], logProbabilities: [regular.id: .nan], weight: 1)
        #expect(invalid.scores[regular.id] == nil)
    }

    @Test func tokenizerMatchesScalarAndByteFallbackWithoutNormalizing() throws {
        let data = Data(#"{"schema_version":1,"vocab_size":16384,"characters":["我","会"]}"#.utf8)
        let tokenizer = try SmallRerankerTokenizer(data: data)
        #expect(tokenizer.encode("我会") == [260, 261])
        #expect(tokenizer.encode("A🙂") == [69, 244, 163, 157, 134])
        #expect(tokenizer.encode("é") != tokenizer.encode("e\u{301}"))
        #expect(tokenizer.encode(String(repeating: "我", count: 256))?.count == 256)
        #expect(tokenizer.encode(String(repeating: "我", count: 257)) == nil)
        #expect(tokenizer.encode("\n") == nil)
    }
}
