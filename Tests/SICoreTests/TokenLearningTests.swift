import Foundation
import Testing
@testable import SICore

struct TokenLearningTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let engine = CandidateEngine()
    private let languages = Set(InputLanguage.allCases)

    @Test(arguments: [1.0, 8, 1_000])
    func legacySingleCharacterPreferencesDoNotDistortWritingRequests(strength: Double) throws {
        let profile = LearningProfile(entries: [
            LearnedPreference(input: "ba", text: "把", language: .simplifiedChinese, strength: strength, lastUsed: now),
            LearnedPreference(input: "xie", text: "些", language: .simplifiedChinese, strength: strength, lastUsed: now),
        ], now: now)
        for enabled: Set<InputLanguage> in [[.simplifiedChinese], languages] {
            for input in ["bangwozaixie", "bangwozaixieyige"] {
                for preview in [false, true] {
                    let baseline = preview
                        ? engine.previewCandidates(for: input, languages: enabled, learning: LearningProfile(), dictionary: UserDictionary(), now: now, context: nil)
                        : engine.candidates(for: input, languages: enabled, now: now)
                    let results = preview
                        ? engine.previewCandidates(for: input, languages: enabled, learning: profile, dictionary: UserDictionary(), now: now, context: nil)
                        : engine.candidates(for: input, languages: enabled, learning: profile, now: now)
                    #expect(results.filter { !$0.isPartial } == baseline.filter { !$0.isPartial })
                    #expect(results.allSatisfy { $0.tokenLearningBonus == 0 })
                    #expect(results.last?.text == input && results.last?.isLiteral == true)
                }
            }
        }
        #expect(engine.candidates(for: "xie", languages: [.simplifiedChinese], learning: profile, now: now).first?.text == "些")
        #expect(profile.entries.count == 2)
    }

    @Test func singleCharacterRecordsStayLocalEvenWhenTheirCodeAlsoHasWordPreferences() throws {
        let character = InputCandidate(text: "把", language: .simplifiedChinese, score: 100)
        let word = InputCandidate(text: "把握", language: .simplifiedChinese, score: 84)
        var profile = LearningProfile()
        profile.record(InputCommit(input: "ba", candidate: character, reason: .explicitSelection), now: now)
        profile.record(InputCommit(input: "ba", candidate: word, reason: .explicitSelection), now: now)
        #expect(profile.tokenBonus(input: "ba", text: "把", language: .simplifiedChinese, now: now) == 0)
        #expect(profile.tokenBonus(input: "ba", text: "把握", language: .simplifiedChinese, now: now) > 0)
        #expect(LearningProfile(entries: profile.entries, now: now) == profile)
        profile.remove(id: try #require(profile.entries.first { $0.text == "把" }?.id))
        #expect(profile.hasTokenPreferences)
        profile.record(InputCommit(input: "ba", candidate: character, reason: .explicitSelection), now: now)
        profile.remove(id: try #require(profile.entries.first { $0.text == "把握" }?.id))
        #expect(!profile.hasTokenPreferences)
        #expect(profile.bonus(for: character, input: "ba", now: now) > 0)
        #expect(LearningProfile(entries: profile.entries, now: now) == profile)
        profile.prune(now: now)
        #expect(!profile.hasTokenPreferences && profile.entries.count == 1)
    }

    @Test func explicitWholeAndPrefixChoicesCanStillOverrideTheBaseWritingCandidate() throws {
        var profile = LearningProfile()
        let alternative = try #require(engine.candidates(for: "bangwozaixie", languages: languages, now: now)
            .first { $0.text == "帮我在写" && !$0.isPartial })
        profile.record(InputCommit(input: "bangwozaixie", candidate: alternative, reason: .explicitSelection), now: now)
        #expect(engine.candidates(for: "bangwozaixie", languages: languages, learning: profile, now: now).first { !$0.isPartial }?.text == "帮我在写")
        var session = InputSession()
        session.configure(languages: languages, learning: profile, now: now)
        session.append("bangwozaixieyige", now: now)
        let prefix = try #require(session.candidates.first { $0.text == "帮我在写" && $0.isPartial })
        let commit = session.commitResult(prefix, reason: .explicitSelection, now: now)
        #expect(commit.input == "bangwozaixie" && commit.remainingInput == "yige")
        #expect(commit.text == "帮我在写")
        profile.record(commit, now: now)
        #expect(profile.entries.count == 1 && profile.entries.first?.input == "bangwozaixie")
    }

    @Test func standaloneWordChoiceGeneralizesInsideAnUnlearnedComposition() throws {
        let profile = try learned(input: "shike", text: "食客")
        let base = engine.candidates(for: "woshike", languages: languages, now: now)
        let ranked = engine.candidates(for: "woshike", languages: languages, learning: profile, now: now)
        #expect(base.first?.text != "我食客")
        #expect(ranked.first?.text == "我食客")
        #expect(ranked.contains { $0.text != "我食客" && !$0.isPartial && !$0.isLiteral })
        #expect(ranked.contains { $0.isMixed })
        #expect(ranked.last?.text == "woshike" && ranked.last?.isLiteral == true)
        #expect(ranked == engine.candidates(for: "woshike", languages: languages, learning: profile, now: now))
        #expect(profile.entries.count == 1)
    }

    @Test func pauseDeletionExpiryAndReloadRestoreTheExpectedRanking() throws {
        var profile = try learned(input: "shike", text: "食客")
        let restored = LearningProfile(entries: profile.entries, now: now)
        #expect(engine.candidates(for: "woshike", languages: languages, learning: restored, now: now).first?.text == "我食客")
        #expect(engine.candidates(for: "woshike", languages: languages, now: now).first?.text != "我食客")
        let expired = now.addingTimeInterval(90 * 86_400)
        #expect(engine.candidates(for: "woshike", languages: languages, learning: profile, now: expired).first?.text != "我食客")
        var pruned = profile
        pruned.prune(now: expired)
        #expect(!pruned.hasTokenPreferences)
        profile.remove(id: try #require(profile.entries.first?.id))
        #expect(!profile.hasTokenPreferences)
        #expect(engine.candidates(for: "woshike", languages: languages, learning: profile, now: now).first?.text != "我食客")
    }

    @Test func deletingOnePreferenceDoesNotDropOtherPreferencesForTheSameCode() throws {
        var profile = try learned(input: "shike", text: "食客")
        let word = InputCandidate(text: "时刻", language: .simplifiedChinese, score: 98)
        profile.record(InputCommit(input: "shike", candidate: word, reason: .explicitSelection), now: now)
        profile.remove(id: try #require(profile.entries.first { $0.text == "食客" }?.id))
        #expect(profile.tokenBonus(input: "shike", text: "时刻", language: .simplifiedChinese, now: now) > 0)
        let copy = profile
        profile.removeAll()
        #expect(!profile.hasTokenPreferences)
        #expect(copy.hasTokenPreferences)
        #expect(LearningProfile(entries: copy.entries, now: now) == copy)
    }

    @Test func contextualAndMixedRecordsCannotBecomeSingleTokenFrequencyRecords() {
        let context = CandidateContext(candidate: InputCandidate(text: "你好", language: .simplifiedChinese, score: 100))
        let profile = LearningProfile(entries: [
            LearnedPreference(input: "shike", text: "食客", language: .simplifiedChinese, strength: 8, lastUsed: now, context: context),
            LearnedPreference(input: "shike", text: "食客", language: .simplifiedChinese, strength: 8, lastUsed: now, isMixed: true),
        ], now: now)
        #expect(!profile.hasTokenPreferences)
        #expect(engine.candidates(for: "woshike", languages: languages, learning: profile, now: now).first?.text != "我食客")
    }

    @Test func personalAndVerbatimPathsNeverReceiveTokenBonusesOrGenerateTokenRecords() throws {
        var profile = try learned(input: "shike", text: "食客")
        let dictionary = try UserDictionary(entries: [UserPhrase(input: "xm", text: "测试人名", language: .simplifiedChinese)])
        for input in ["shikexm", "shikeQzXvJk"] {
            let candidates = engine.candidates(for: input, languages: languages, learning: profile, dictionary: dictionary, now: now)
            let privateCandidates = candidates.filter { $0.isUserPhrase || $0.hasLiteralSegments }
            #expect(!privateCandidates.isEmpty, "Input: \(input)")
            for candidate in privateCandidates {
                #expect(candidate.tokenLearningBonus == 0)
                #expect(profile.rankingScore(for: candidate, input: input, now: now, context: nil) == candidate.rankingScore)
                let recorded = profile.record(InputCommit(input: input, candidate: candidate, reason: .explicitSelection), now: now)
                #expect(!recorded)
            }
        }
        let composed = try #require(engine.candidates(for: "woshike", languages: languages, learning: profile, now: now)
            .first { $0.text == "我食客" && !$0.isPartial })
        profile.record(InputCommit(input: "woshike", candidate: composed, reason: .explicitSelection), now: now)
        #expect(profile.entries.count == 2)
        #expect(profile.entries.filter { $0.input == "shike" }.count == 1)
    }

    @Test func prefixRankingUsesOnlyConsumedTokensAndCompetesByEffectiveScore() throws {
        let profile = try learned(input: "shike", text: "食客")
        let candidates = engine.candidates(for: "woshikenihao", languages: languages, learning: profile, now: now)
        let prefix = try #require(candidates.first { $0.text == "我食客" && $0.consumedInputCount == 7 })
        #expect(abs(prefix.tokenLearningBonus - 32 * 5 / 7) < 0.0001)
        var session = InputSession(candidateGeneration: .deferred)
        session.configure(languages: languages, learning: profile, now: now)
        session.append("woshikenihao", now: now)
        let scores = candidates.filter { $0.consumedInputCount == prefix.consumedInputCount }
            .map { session.presentationScore(for: $0, now: now) }
        #expect(scores == scores.sorted(by: >))
    }

    private func learned(input: String, text: String, language: InputLanguage = .simplifiedChinese) throws -> LearningProfile {
        let target = try #require(engine.candidates(for: input, languages: [language], now: now)
            .first { $0.text == text && !$0.isPartial })
        var profile = LearningProfile()
        for _ in 0..<8 { profile.record(InputCommit(input: input, candidate: target, reason: .explicitSelection), now: now) }
        return profile
    }
}
