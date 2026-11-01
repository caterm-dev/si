import Foundation
import Testing
@testable import SICore

struct PrefixLearningTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test(arguments: ["LÜ'SE'", "lu:'se'"])
    func prefixLearningUsesOnlyConsumedSpellingAndRetainsItsFullCappedBonus(input: String) throws {
        let text = "绿色"
        let context = try #require(CandidateContext(candidate: InputCandidate(text: "你好", language: .simplifiedChinese, score: 0)))
        let key = LearningProfile.normalizedInput(input, language: .simplifiedChinese)
        let profile = LearningProfile(entries: [
            LearnedPreference(input: key, text: text, language: .simplifiedChinese, strength: 1_000, lastUsed: now),
            LearnedPreference(input: key, text: text, language: .simplifiedChinese, strength: 1_000, lastUsed: now, context: context),
        ], now: now)
        let prefix = InputCandidate(text: text, language: .simplifiedChinese, score: 10,
                                    consumedInputCount: input.count, tokenLearningBonus: 24)
        let ranking = profile.ranking(for: input, now: now, context: context)
        let score = profile.rankingScore(for: prefix, input: input, now: now, context: context)
        #expect(abs(score - (prefix.inputScore + 32 + 12)) < 1e-12)
        #expect(ranking.score(prefix) == score)
        #expect(prefix.rankingScore == 10 && prefix.inputScore == 10)

        let whole = InputCandidate(text: text, language: .simplifiedChinese, score: 10, tokenLearningBonus: 24)
        #expect(profile.rankingScore(for: whole, input: input, now: now, context: context) == 54)
        #expect(profile.bonus(for: prefix, input: input, now: now, context: context) == 44)
    }

    @Test func aCharacterKeepsItsStandaloneScoreAcrossDifferentFollowingInputs() throws {
        let engine = CandidateEngine()
        let profile = LearningProfile(entries: [
            LearnedPreference(input: "ci'", text: "词", language: .simplifiedChinese, strength: 8, lastUsed: now),
        ], now: now)
        for languages: Set<InputLanguage> in [[.simplifiedChinese], Set(InputLanguage.allCases)] {
            let standalone = try #require(engine.candidates(for: "ci'", languages: languages, learning: profile, now: now)
                .first { $0.text == "词" && !$0.isPartial })
            let expected = profile.rankingScore(for: standalone, input: "ci'", now: now, context: nil) + 10
            for input in ["ci'chuxian'de", "ci'nihao", "ci'hello", "ci'xyz", "ci'nihaopengyouzaijian"] {
                var session = InputSession(candidateGeneration: .deferred)
                session.configure(languages: languages, learning: profile)
                session.append(input, now: now)
                let request = try #require(session.pendingCandidateRequest)
                for result in [request.generatePreview(), request.generate()] {
                    let prefix = try #require(result.candidates.first { $0.text == "词" && $0.consumedInputCount == 3 })
                    #expect(prefix.rankingScore == standalone.rankingScore)
                    #expect(session.presentationScore(for: prefix, now: now) == expected)
                    let accepted = session.accept(result)
                    #expect(accepted)
                    #expect(result.candidates.last?.text == input && result.candidates.last?.isLiteral == true)
                }
            }
        }
    }

    @Test func appVocabularyKeepsUsageAndConsumedPrefixLearningSeparate() throws {
        let engine = CandidateEngine()
        let character = try #require(engine.candidates(for: "shi", languages: [.simplifiedChinese])
            .first { $0.text == "是" && !$0.isPartial })
        let phrase = try #require(engine.candidates(for: "shizenme", languages: [.simplifiedChinese])
            .first { $0.text == "是怎么" && !$0.isPartial })
        var memory = ApplicationMemory()
        for _ in 0..<5 {
            let recorded = memory.recordVocabulary(InputCommit(input: "shi", candidate: character, reason: .defaultAcceptance),
                                                    now: now)
            #expect(recorded)
        }
        let recorded = memory.recordVocabulary(InputCommit(input: "shizenme", candidate: phrase, reason: .defaultAcceptance),
                                                now: now)
        #expect(recorded)
        let saved = memory.vocabulary
        let snapshot = memory.snapshot(vocabularyEnabled: true, now: now)
        for languages: Set<InputLanguage> in [[.simplifiedChinese], Set(InputLanguage.allCases)] {
            var session = InputSession(engine: engine, candidateGeneration: .deferred)
            session.configure(languages: languages, learning: snapshot.learning, applicationMemory: snapshot)
            session.append("shizenme", now: now)
            let request = try #require(session.pendingCandidateRequest)
            for result in [request.generatePreview(), request.generate()] {
                #expect(result.candidates.contains { $0.id == phrase.id })
                let prefix = try #require(result.candidates.first { $0.text == "是" && $0.consumedInputCount == 3 })
                #expect(session.presentationScore(for: prefix, now: now) == character.rankingScore + 15)
                #expect(abs(prefix.rankingScore - character.rankingScore) < 1e-12)
                #expect(result.candidates.last?.text == "shizenme" && result.candidates.last?.isLiteral == true)
            }
        }
        #expect(memory.vocabulary == saved)
        #expect(saved.first { $0.preference.input == "shi" }?.count == 5)
        #expect(saved.first { $0.preference.input == "shizenme" }?.count == 1)

        // Repeated default acceptance records usage without adding ranking strength.
        memory.removeVocabulary(id: try #require(saved.first { $0.preference.input == "shizenme" }?.id))
        let prefixOnly = memory.snapshot(vocabularyEnabled: true, now: now)
        let candidates = engine.candidates(for: "shizenme", languages: [.simplifiedChinese],
                                           learning: prefixOnly.learning, now: now, applicationMemory: prefixOnly)
        #expect(candidates.contains { $0.id == phrase.id })
        let prefix = try #require(candidates.first { $0.text == "是" && $0.consumedInputCount == 3 })
        // Explicit corrections add a bonus only for the consumed prefix spelling.
        for _ in 0..<72 {
            memory.recordVocabulary(InputCommit(input: "shi", candidate: prefix, reason: .explicitSelection),
                                    now: now)
        }
        let corrected = memory.snapshot(vocabularyEnabled: true, now: now)
        let ranked = engine.candidates(for: "shizenme", languages: [.simplifiedChinese],
                                       learning: corrected.learning, now: now, applicationMemory: corrected)
        #expect(ranked.first?.id == prefix.id)
    }
}
