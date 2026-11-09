import Foundation
import Testing
@testable import SICore

struct KenLMContextTests {
    @Test func keepsOnlyThreeRecentChineseWordsAndResetsAtBoundaries() {
        #expect(KenLMContext(text: "我 今天 想 要").tokens == ["今天", "想", "要"])
        for boundary in ["。", "，", "\n", "\r", "deploy", "👩‍💻"] {
            #expect(KenLMContext(text: "以前" + boundary + "我 今天").tokens == ["我", "今天"])
            #expect(KenLMContext(text: "我 今天" + boundary).tokens.isEmpty)
        }
        #expect(KenLMContext(text: String(repeating: "我", count: 257)).tokens.isEmpty)
        #expect(KenLMContext(text: "今天", isTruncated: true).tokens.isEmpty)
    }

    @Test func changedContextRejectsOldRequestsAndResetDropsContext() throws {
        var session = InputSession(candidateGeneration: .deferred)
        session.append("ni")
        let old = try #require(session.pendingCandidateRequest)
        session.setLanguageModelContext(KenLMContext(text: "我 今天"))
        let latest = try #require(session.pendingCandidateRequest)
        let acceptedOld = session.accept(old.generate())
        let acceptedPreview = session.accept(old.generatePreview())
        #expect(latest.id != old.id && !acceptedOld && !acceptedPreview)
        session.setLanguageModelContext(KenLMContext(text: "我 今天"))
        #expect(session.pendingCandidateRequest?.id == latest.id)
        session.reset()
        let acceptedAfterReset = session.accept(latest.generate())
        #expect(!acceptedAfterReset)
        session.append("hao")
        let fresh = try #require(session.pendingCandidateRequest)
        session.setLanguageModelContext(.empty)
        #expect(session.pendingCandidateRequest?.id == fresh.id)
        session.setLanguageModelContext(KenLMContext(text: "今天"))
        session.configure(languages: [.simplifiedChinese], contextGeneration: 1)
        let afterFocusChange = try #require(session.pendingCandidateRequest)
        session.setLanguageModelContext(.empty)
        #expect(session.pendingCandidateRequest?.id == afterFocusChange.id)
        session.reset()
        session.setLanguageModelContext(KenLMContext(text: "今天"))
        session.append("ni")
        let afterEmptyBuffer = try #require(session.pendingCandidateRequest)
        session.setLanguageModelContext(.empty)
        #expect(session.pendingCandidateRequest?.id == afterEmptyBuffer.id)
    }

    @Test func preparedStateMatchesIncrementalNativeScoresWithoutCandidateContamination() throws {
        guard let path = ProcessInfo.processInfo.environment["SI_TEST_KENLM_BUNDLE"] else { return }
        let model = try #require(KenLMModel.openBundled(at: URL(fileURLWithPath: path)))
        let prefix = ["我", "今天"]
        var scorer = KenLMScorer(model: model)
        let prepared = scorer.state(after: prefix)
        let initial = try #require(prepared)
        for words in [["去"], ["取"], ["趣"], ["去", "学校"], ["去"]] {
            var state = model.beginSentence()
            for word in prefix {
                let index = try #require(model.wordIndex(word)).index
                state = try #require(model.advance(state, wordIndex: index)).state
            }
            var expected = 0.0
            for word in words {
                let index = try #require(model.wordIndex(word)).index
                let step = try #require(model.advance(state, wordIndex: index))
                expected += step.log10 * log2(10.0)
                state = step.state
            }
            let tokens = words.map { RankingToken(text: $0, language: .simplifiedChinese, weight: 1) }
            let result = scorer.score(tokens, language: .simplifiedChinese, startingAt: initial)
            let score = try #require(result)
            #expect(abs(score.bits - expected) < 0.000001)
        }
        let context = KenLMContext(text: "我 今天")
        let input = "qu"
        let languages: Set<InputLanguage> = [.simplifiedChinese, .english]
        let candidates = CandidateEngine().candidates(for: input, languages: languages)
        let config = RankingExperiment(model: model, languageModelWeight: 0.25, fullCoverageFirst: true)
        let expected = CandidateRankingPool(candidates: candidates, model: model, context: prefix).ranked(using: config)
        let actual = CandidateEngine(rankingExperiment: config).candidates(for: input, languages: languages,
                                                                          languageModelContext: context)
        #expect(actual == expected)
        #expect(actual.contains { $0.text == input && $0.isLiteral })
        let mixed = [RankingToken(text: "deploy", language: .english, weight: 1),
                     RankingToken(text: "学校", language: .simplifiedChinese, weight: 1)]
        let mixedScore = scorer.score(mixed, language: .simplifiedChinese, startingAt: initial)
        let standaloneScore = scorer.score(Array(mixed.suffix(1)), language: .simplifiedChinese)
        let reset = try #require(mixedScore)
        let standalone = try #require(standaloneScore)
        #expect(reset.bits == standalone.bits)
    }
}
