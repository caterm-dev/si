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
                    #expect(results == baseline)
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
        #expect(engine.candidates(for: "bangwozaixie", languages: languages, learning: profile, now: now).first?.text == "帮我在写")
        var session = InputSession()
        session.configure(languages: languages, learning: profile, now: now)
        session.append("bangwozaixieyige")
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

    @Test func preferenceParticipatesBeforeTheBeamDiscardsAnAlternative() throws {
        let alternatives = (0..<30).map {
            PinyinLexiconEntry(syllables: ["xi", "zi"], text: "字" + String(UnicodeScalar(0x4e00 + $0)!), score: 100 - $0)
        }
        let tiny = PinyinDecoder(entries: [PinyinLexiconEntry(syllables: ["wo"], text: "我")] + alternatives)
        let target = try #require(tiny.candidates(for: "xizi").first { $0.text == alternatives.last?.text })
        var profile = LearningProfile()
        for _ in 0..<8 { profile.record(InputCommit(input: "xizi", candidate: target, reason: .explicitSelection), now: now) }
        let output = "我" + target.text
        #expect(!tiny.candidates(for: "woxizi").contains { $0.text == output })
        let ranked = tiny.compositionCandidates(for: "woxizi", languages: [.simplifiedChinese], learning: profile, now: now)
        #expect(ranked.first?.text == output)
        #expect(ranked.first?.tokenLearningBonus ?? 0 > 0)
    }

    @Test func englishFinalCompletionsUseTheirOwnSpellingAndLanguage() throws {
        let profile = try learned(input: "fi", text: "find", language: .english)
        // Isolate learning from the maintained Chinese homophone fanout.
        let decoder = PinyinDecoder(entries: [PinyinLexiconEntry(syllables: ["ni", "hao"], text: "你好")])
        let ranked = decoder.compositionCandidates(for: "nihaofi", languages: languages, learning: profile, now: now)
        let find = try #require(ranked.firstIndex { $0.text == "你好find" && !$0.isPartial })
        let first = try #require(ranked.firstIndex { $0.text == "你好first" && !$0.isPartial })
        #expect(find < first)
        #expect(ranked[find].hasCompletion && ranked[find].canLearn && ranked[find].tokenLearningBonus > 0)
        #expect(!engine.candidates(for: "nihaofi", languages: [.simplifiedChinese], learning: profile, now: now)
            .contains { $0.text == "你好find" })
    }

    @Test func normalizedAliasesShareTokenPreferencesAndSyllableBoundariesStayDistinct() throws {
        // Boundary eligibility is independent of the maintained vocabulary's changing frequency shortlist.
        let decoder = PinyinDecoder(entries: [
            PinyinLexiconEntry(syllables: ["wo"], text: "我"),
            PinyinLexiconEntry(syllables: ["lv", "se"], text: "绿色"),
            PinyinLexiconEntry(syllables: ["xian"], text: "先"),
            PinyinLexiconEntry(syllables: ["xi", "an"], text: "西安", score: 99),
        ])
        let profile = try learned(input: "lu:se", text: "绿色")
        for input in ["wolvse", "woLÜse", "wolu:se"] {
            let word = try #require(decoder.compositionCandidates(for: input, languages: [.simplifiedChinese], learning: profile, now: now)
                .first { $0.text == "我绿色" && !$0.isPartial })
            #expect(word.tokenLearningBonus > 0)
        }
        let cityProfile = try learned(input: "xi'an", text: "西安")
        let separated = try #require(decoder.compositionCandidates(for: "woxi'an", languages: languages, learning: cityProfile, now: now)
            .first { $0.text == "我西安" && !$0.isPartial })
        let plain = try #require(decoder.compositionCandidates(for: "woxian", languages: languages, learning: cityProfile, now: now)
            .first { $0.text == "我西安" && !$0.isPartial })
        #expect(separated.tokenLearningBonus > 0)
        #expect(plain.tokenLearningBonus == 0)
    }

    @Test func repeatedTokensAndWholeInputPreferencesShareOneFrequencyCap() throws {
        var profile = try learned(input: "shike", text: "食客")
        let input = String(repeating: "shike", count: 10)
        let balanced = PinyinDecoder(entries: [PinyinLexiconEntry(syllables: ["shi", "ke"], text: "食客"),
                                                PinyinLexiconEntry(syllables: ["shi", "ke"], text: "时刻", score: 99)])
        let repeated = try #require(balanced.compositionCandidates(for: input, languages: [.simplifiedChinese], learning: profile, now: now)
            .first { $0.text == String(repeating: "食客", count: 10) && !$0.isPartial })
        #expect(repeated.tokenLearningBonus == 32)
        #expect(profile.rankingScore(for: repeated, input: input, now: now, context: nil) - repeated.rankingScore == 32)

        let context = try #require(CandidateContext(candidate: InputCandidate(text: "你好", language: .simplifiedChinese, score: 100)))
        let whole = InputCandidate(text: "我食客", language: .simplifiedChinese, score: 90)
        for _ in 0..<8 {
            profile.record(InputCommit(input: "woshike", candidate: whole, reason: .explicitSelection, context: context),
                           now: now, learnContext: true)
        }
        let ranked = try #require(engine.candidates(for: "woshike", languages: languages, learning: profile, now: now, context: context)
            .first { $0.text == "我食客" && !$0.isPartial })
        let adjustment = profile.rankingScore(for: ranked, input: "woshike", now: now, context: context) - ranked.rankingScore
        #expect(abs(adjustment - 44) < 0.0001)
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

    @Test func deduplicationChoosesTheStrongestDerivationAfterApplyingTheSharedCap() throws {
        let tiny = PinyinDecoder(entries: [
            PinyinLexiconEntry(syllables: ["wo"], text: "我"),
            PinyinLexiconEntry(syllables: ["shi", "ke"], text: "食客"),
            PinyinLexiconEntry(syllables: ["wo", "shi", "ke"], text: "我食客", score: 100),
        ])
        let base = try #require(tiny.candidates(for: "woshike").first { $0.text == "我食客" })
        var profile = try learned(input: "shike", text: "食客")
        let tokenRanked = try #require(tiny.compositionCandidates(for: "woshike", languages: [.simplifiedChinese], learning: profile, now: now)
            .first { $0.text == "我食客" && !$0.isPartial })
        #expect(tokenRanked.tokenLearningBonus > 0)
        for _ in 0..<8 {
            profile.record(InputCommit(input: "woshike", candidate: tokenRanked, reason: .explicitSelection), now: now)
        }
        let candidates = tiny.compositionCandidates(for: "woshike", languages: [.simplifiedChinese], learning: profile, now: now)
        let wholeRanked = try #require(candidates.first { $0.text == "我食客" && !$0.isPartial })
        #expect(candidates.count { $0.id == wholeRanked.id } == 1)
        #expect(wholeRanked.rankingScore == base.rankingScore)
        // Reusing the whole-input record as token evidence must not add another frequency bonus.
        #expect(profile.rankingScore(for: wholeRanked, input: "woshike", now: now, context: nil) - wholeRanked.rankingScore == 32)
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
        for input in ["shikexm", "shikeQwErTy"] {
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
        let scores = candidates.dropLast().map { candidate in
            let spelling = candidate.consumedInputCount.map { String("woshikenihao".prefix($0)) } ?? "woshikenihao"
            return profile.rankingScore(for: candidate, input: spelling, now: now, context: nil)
        }
        #expect(scores == scores.sorted(by: >))
    }

    @Test func canonicallyEquivalentTextStaysDeduplicatedThroughRepeatedPruning() throws {
        let tiny = PinyinDecoder(entries: [
            PinyinLexiconEntry(syllables: ["wo"], text: "我"),
            PinyinLexiconEntry(syllables: ["shi"], text: "字é"),
            PinyinLexiconEntry(syllables: ["shi"], text: "字e\u{301}"),
        ])
        let token = try #require(tiny.candidates(for: "shi").first)
        var profile = LearningProfile()
        profile.record(InputCommit(input: "shi", candidate: token, reason: .explicitSelection), now: now)
        let input = "wo" + String(repeating: "shi", count: 4)
        let candidates = tiny.compositionCandidates(for: input, languages: [.simplifiedChinese], learning: profile, now: now)
        #expect(candidates.count { $0.text == "我字é字é字é字é" && !$0.isPartial } == 1)
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
