import Foundation
import Testing
@testable import SICore

struct TokenLearningTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let engine = CandidateEngine()
    private let languages = Set(InputLanguage.allCases)

    @Test func standaloneChoiceGeneralizesInsideAnUnlearnedComposition() throws {
        let profile = try learned(input: "shi", text: "时")
        let base = engine.candidates(for: "woshi", languages: languages, now: now)
        let ranked = engine.candidates(for: "woshi", languages: languages, learning: profile, now: now)
        #expect(base.first?.text == "我是")
        #expect(ranked.first?.text == "我时")
        #expect(ranked.contains { $0.text == "我是" })
        #expect(ranked.contains { $0.isMixed })
        #expect(ranked.last?.text == "woshi" && ranked.last?.isLiteral == true)
        #expect(ranked == engine.candidates(for: "woshi", languages: languages, learning: profile, now: now))
        #expect(profile.entries.count == 1)
    }

    @Test func preferenceParticipatesBeforeTheBeamDiscardsAnAlternative() throws {
        let alternatives = (0..<30).map {
            PinyinLexiconEntry(syllables: ["xi"], text: String(UnicodeScalar(0x4e00 + $0)!), score: 100 - $0)
        }
        let tiny = PinyinDecoder(entries: [PinyinLexiconEntry(syllables: ["wo"], text: "我")] + alternatives)
        let target = try #require(tiny.candidates(for: "xi").first { $0.text == alternatives.last?.text })
        var profile = LearningProfile()
        for _ in 0..<8 { profile.record(InputCommit(input: "xi", candidate: target, reason: .explicitSelection), now: now) }
        let output = "我" + target.text
        #expect(!tiny.candidates(for: "woxi").contains { $0.text == output })
        let ranked = tiny.compositionCandidates(for: "woxi", languages: [.simplifiedChinese], learning: profile, now: now)
        #expect(ranked.first?.text == output)
        #expect(ranked.first?.tokenLearningBonus ?? 0 > 0)
    }

    @Test func englishFinalCompletionsUseTheirOwnSpellingAndLanguage() throws {
        let profile = try learned(input: "fi", text: "find", language: .english)
        let ranked = engine.candidates(for: "nihaofi", languages: languages, learning: profile, now: now)
        let find = try #require(ranked.firstIndex { $0.text == "你好find" && !$0.isPartial })
        let file = try #require(ranked.firstIndex { $0.text == "你好file" && !$0.isPartial })
        #expect(find < file)
        #expect(ranked[find].hasCompletion && ranked[find].canLearn && ranked[find].tokenLearningBonus > 0)
        #expect(!engine.candidates(for: "nihaofi", languages: [.simplifiedChinese], learning: profile, now: now)
            .contains { $0.text == "你好find" })
    }

    @Test func normalizedAliasesShareTokenPreferencesAndSyllableBoundariesStayDistinct() throws {
        let profile = try learned(input: "lu:", text: "吕")
        for input in ["wolv", "woLÜ", "wolu:"] {
            #expect(engine.candidates(for: input, languages: [.simplifiedChinese], learning: profile, now: now).first?.text == "我吕")
        }
        let cityProfile = try learned(input: "xi'an", text: "西安")
        let separated = try #require(engine.candidates(for: "woxi'an", languages: languages, learning: cityProfile, now: now)
            .first { $0.text == "我西安" && !$0.isPartial })
        let plain = try #require(engine.candidates(for: "woxian", languages: languages, learning: cityProfile, now: now)
            .first { $0.text == "我西安" && !$0.isPartial })
        #expect(separated.tokenLearningBonus > 0)
        #expect(plain.tokenLearningBonus == 0)
    }

    @Test func repeatedTokensAndWholeInputPreferencesShareOneFrequencyCap() throws {
        var profile = try learned(input: "shi", text: "时")
        let input = String(repeating: "shi", count: 10)
        let repeated = try #require(engine.candidates(for: input, languages: [.simplifiedChinese], learning: profile, now: now)
            .first { $0.text == String(repeating: "时", count: 10) && !$0.isPartial })
        #expect(repeated.tokenLearningBonus == 32)
        #expect(profile.rankingScore(for: repeated, input: input, now: now, context: nil) - repeated.rankingScore == 32)

        let context = try #require(CandidateContext(candidate: InputCandidate(text: "你好", language: .simplifiedChinese, score: 100)))
        let whole = InputCandidate(text: "我时", language: .simplifiedChinese, score: 90)
        for _ in 0..<8 {
            profile.record(InputCommit(input: "woshi", candidate: whole, reason: .explicitSelection, context: context),
                           now: now, learnContext: true)
        }
        let ranked = try #require(engine.candidates(for: "woshi", languages: languages, learning: profile, now: now, context: context)
            .first { $0.text == "我时" && !$0.isPartial })
        let adjustment = profile.rankingScore(for: ranked, input: "woshi", now: now, context: context) - ranked.rankingScore
        #expect(adjustment == 44)
    }

    @Test func pauseDeletionExpiryAndReloadRestoreTheExpectedRanking() throws {
        var profile = try learned(input: "shi", text: "时")
        let restored = LearningProfile(entries: profile.entries, now: now)
        #expect(engine.candidates(for: "woshi", languages: languages, learning: restored, now: now).first?.text == "我时")
        #expect(engine.candidates(for: "woshi", languages: languages, now: now).first?.text == "我是")
        let expired = now.addingTimeInterval(90 * 86_400)
        #expect(engine.candidates(for: "woshi", languages: languages, learning: profile, now: expired).first?.text == "我是")
        var pruned = profile
        pruned.prune(now: expired)
        #expect(!pruned.hasTokenPreferences)
        profile.remove(id: try #require(profile.entries.first?.id))
        #expect(!profile.hasTokenPreferences)
        #expect(engine.candidates(for: "woshi", languages: languages, learning: profile, now: now).first?.text == "我是")
    }

    @Test func deduplicationChoosesTheStrongestDerivationAfterApplyingTheSharedCap() throws {
        var profile = try learned(input: "shi", text: "是")
        let tokenRanked = try #require(engine.candidates(for: "woshi", languages: languages, learning: profile, now: now)
            .first { $0.text == "我是" && !$0.isPartial })
        #expect(tokenRanked.tokenLearningBonus > 0)
        for _ in 0..<8 {
            profile.record(InputCommit(input: "woshi", candidate: tokenRanked, reason: .explicitSelection), now: now)
        }
        let candidates = engine.candidates(for: "woshi", languages: languages, learning: profile, now: now)
        let wholeRanked = try #require(candidates.first { $0.text == "我是" && !$0.isPartial })
        #expect(candidates.count { $0.id == wholeRanked.id } == 1)
        #expect(wholeRanked.rankingScore == 100)
        #expect(wholeRanked.tokenLearningBonus == 0)
        #expect(profile.rankingScore(for: wholeRanked, input: "woshi", now: now, context: nil) == 132)
    }

    @Test func deletingOnePreferenceDoesNotDropOtherPreferencesForTheSameCode() throws {
        var profile = try learned(input: "shi", text: "时")
        let word = InputCandidate(text: "事", language: .simplifiedChinese, score: 98)
        profile.record(InputCommit(input: "shi", candidate: word, reason: .explicitSelection), now: now)
        profile.remove(id: try #require(profile.entries.first { $0.text == "时" }?.id))
        #expect(profile.tokenBonus(input: "shi", text: "事", language: .simplifiedChinese, now: now) > 0)
        let copy = profile
        profile.removeAll()
        #expect(!profile.hasTokenPreferences)
        #expect(copy.hasTokenPreferences)
        #expect(LearningProfile(entries: copy.entries, now: now) == copy)
    }

    @Test func contextualAndMixedRecordsCannotBecomeSingleTokenFrequencyRecords() {
        let context = CandidateContext(candidate: InputCandidate(text: "你好", language: .simplifiedChinese, score: 100))
        let profile = LearningProfile(entries: [
            LearnedPreference(input: "shi", text: "时", language: .simplifiedChinese, strength: 8, lastUsed: now, context: context),
            LearnedPreference(input: "shi", text: "时", language: .simplifiedChinese, strength: 8, lastUsed: now, isMixed: true),
        ], now: now)
        #expect(!profile.hasTokenPreferences)
        #expect(engine.candidates(for: "woshi", languages: languages, learning: profile, now: now).first?.text == "我是")
    }

    @Test func personalAndVerbatimPathsNeverReceiveTokenBonusesOrGenerateTokenRecords() throws {
        var profile = try learned(input: "shi", text: "时")
        let dictionary = try UserDictionary(entries: [UserPhrase(input: "xm", text: "测试人名", language: .simplifiedChinese)])
        for input in ["shixm", "shiQwErTy"] {
            let candidates = engine.candidates(for: input, languages: languages, learning: profile, dictionary: dictionary, now: now)
            let privateCandidates = candidates.filter { $0.isUserPhrase || $0.hasLiteralSegments }
            #expect(!privateCandidates.isEmpty)
            for candidate in privateCandidates {
                #expect(candidate.tokenLearningBonus == 0)
                #expect(profile.rankingScore(for: candidate, input: input, now: now, context: nil) == candidate.rankingScore)
                let recorded = profile.record(InputCommit(input: input, candidate: candidate, reason: .explicitSelection), now: now)
                #expect(!recorded)
            }
        }
        let composed = try #require(engine.candidates(for: "woshi", languages: languages, learning: profile, now: now)
            .first { $0.text == "我时" && !$0.isPartial })
        profile.record(InputCommit(input: "woshi", candidate: composed, reason: .explicitSelection), now: now)
        #expect(profile.entries.count == 2)
        #expect(profile.entries.filter { $0.input == "shi" }.count == 1)
    }

    @Test func prefixRankingUsesOnlyConsumedTokensAndStillFollowsWholeCandidates() throws {
        let profile = try learned(input: "shi", text: "时")
        let candidates = engine.candidates(for: "woshinihao", languages: languages, learning: profile, now: now)
        let prefix = try #require(candidates.first { $0.text == "我时" && $0.consumedInputCount == 5 })
        #expect(abs(prefix.tokenLearningBonus - 32 * 3 / 5) < 0.0001)
        let firstPrefix = try #require(candidates.firstIndex { $0.isPartial })
        #expect(candidates[..<firstPrefix].allSatisfy { !$0.isPartial })
        #expect(candidates[firstPrefix..<candidates.count - 1].allSatisfy { $0.isPartial })
    }

    @Test func canonicallyEquivalentTextStaysDeduplicatedThroughRepeatedPruning() throws {
        let tiny = PinyinDecoder(entries: [
            PinyinLexiconEntry(syllables: ["wo"], text: "我"),
            PinyinLexiconEntry(syllables: ["shi"], text: "é"),
            PinyinLexiconEntry(syllables: ["shi"], text: "e\u{301}"),
        ])
        let token = try #require(tiny.candidates(for: "shi").first)
        var profile = LearningProfile()
        profile.record(InputCommit(input: "shi", candidate: token, reason: .explicitSelection), now: now)
        let input = "wo" + String(repeating: "shi", count: 4)
        let candidates = tiny.compositionCandidates(for: input, languages: [.simplifiedChinese], learning: profile, now: now)
        #expect(candidates.count { $0.text == "我éééé" && !$0.isPartial } == 1)
        #expect(Set(candidates.map(\.id)).count == candidates.count)
        #expect(candidates == tiny.compositionCandidates(for: input, languages: [.simplifiedChinese], learning: profile, now: now))
    }

    private func learned(input: String, text: String, language: InputLanguage = .simplifiedChinese) throws -> LearningProfile {
        let target = try #require(engine.candidates(for: input, languages: [language], now: now)
            .first { $0.text == text && !$0.isPartial })
        var profile = LearningProfile()
        for _ in 0..<8 { profile.record(InputCommit(input: input, candidate: target, reason: .explicitSelection), now: now) }
        return profile
    }
}
