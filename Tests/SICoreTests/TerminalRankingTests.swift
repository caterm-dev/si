import Foundation
import Testing
@testable import SICore

struct TerminalRankingTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func standardIncompleteSpellingKeepsTheStrongestDerivationAndCompletionFlag() throws {
        let engine = CandidateEngine()
        let languages = Set(InputLanguage.allCases)
        let original = engine.candidates(for: "niha", languages: languages, now: now)
        let greeting = try #require(original.first { $0.text == "你好" && !$0.isPartial })
        #expect(greeting.rankingScore.isFinite)
        #expect(greeting.hasCompletion)
        var profile = LearningProfile()
        profile.record(InputCommit(input: "niha", candidate: greeting, reason: .explicitSelection), now: now)
        let learned = engine.candidates(for: "niha", languages: languages, learning: profile, now: now)
        #expect(learned.first?.text == "你好")
        #expect(learned.first?.hasCompletion == true)
        #expect(learned.last?.text == "niha" && learned.last?.isLiteral == true)
    }

    @Test func terminalDeduplicationKeepsTheHigherScoringConstructedDerivation() throws {
        let decoder = PinyinDecoder(entries: [
            PinyinLexiconEntry(syllables: ["wo"], text: "我", upstreamWeight: 1_000_000),
            PinyinLexiconEntry(syllables: ["shi"], text: "是", upstreamWeight: 100_000),
            PinyinLexiconEntry(syllables: ["wo", "shi"], text: "我是", score: 0),
        ])
        let candidates = decoder.candidates(for: "woshi")
        let result = try #require(candidates.first { $0.text == "我是" })
        let lexical = (log(1_000_000.0 * 100_000) - 44) / log(2.0)
        let spelling = log2(64.0 / 67) + log2(128.0 / 135)
        let expected = lexical - 1 + log2(1 - RankingCalibration.switchProbability) + spelling
        #expect(abs(result.rankingScore - expected) < 1e-10)
        #expect(candidates.count { $0.text == "我是" } == 1)
    }

    @Test func lowScoringDirectWordsCannotCrowdOutBetterConstructedWords() {
        let direct = (0..<24).map {
            PinyinLexiconEntry(syllables: ["wo", "shi"], text: String(UnicodeScalar(0x5000 + $0)!), score: 0)
        }
        let decoder = PinyinDecoder(entries: direct + [
            PinyinLexiconEntry(syllables: ["wo"], text: "我", upstreamWeight: 1_000_000),
            PinyinLexiconEntry(syllables: ["shi"], text: "是", upstreamWeight: 100_000),
        ])
        let candidates = decoder.candidates(for: "woshi")
        #expect(candidates.first?.text == "我是")
        #expect(direct.allSatisfy { entry in candidates.contains { $0.text == entry.text } })
    }

    @Test func wholeInputLearningAppliesBeforeTerminalAlternativesArePruned() throws {
        let (decoder, target) = fixture()
        #expect(!decoder.candidates(for: "aa").contains { $0.text == target.text })
        var profile = LearningProfile()
        for _ in 0..<8 { profile.record(InputCommit(input: "aa", candidate: target, reason: .explicitSelection), now: now) }
        let candidates = decoder.compositionCandidates(for: "aa", languages: [.simplifiedChinese], learning: profile, now: now)
        #expect(candidates.first?.text == target.text)
        profile.removeAll()
        #expect(!decoder.compositionCandidates(for: "aa", languages: [.simplifiedChinese], learning: profile, now: now)
            .contains { $0.text == target.text })
    }

    @Test func previousWordPairsApplyBeforeTerminalPruningWithoutAUnigramOrTokenRecord() throws {
        let (decoder, target) = fixture()
        let context = try #require(CandidateContext(candidate: InputCandidate(text: "你好", language: .simplifiedChinese, score: 100)))
        var profile = LearningProfile()
        profile.record(InputCommit(input: "aa", candidate: target, reason: .explicitSelection, context: context),
                       now: now, learnContext: true)
        profile.remove(id: try #require(profile.entries.first { $0.context == nil }?.id))
        #expect(!profile.hasTokenPreferences)
        let contextual = decoder.compositionCandidates(for: "aa", languages: [.simplifiedChinese], learning: profile, now: now, context: context)
        #expect(contextual.first?.text == target.text)
        #expect(!decoder.compositionCandidates(for: "aa", languages: [.simplifiedChinese], learning: profile, now: now)
            .contains { $0.text == target.text })
    }

    @Test func contextOnlyPrefixPreferencesStopAfterDeletionAndExpiry() throws {
        let (decoder, target) = fixture(includingSuffix: true)
        let context = try #require(CandidateContext(candidate: InputCandidate(text: "你好", language: .simplifiedChinese, score: 100)))
        var profile = LearningProfile()
        profile.record(InputCommit(input: "aa", candidate: target, reason: .explicitSelection, context: context),
                       now: now, learnContext: true)
        profile.remove(id: try #require(profile.entries.first { $0.context == nil }?.id))
        func hasTarget(_ profile: LearningProfile, context: CandidateContext?, at date: Date) -> Bool {
            decoder.compositionCandidates(for: "aab", languages: [.simplifiedChinese], learning: profile, now: date, context: context)
                .contains { $0.text == target.text && $0.consumedInputCount == 2 }
        }
        #expect(hasTarget(profile, context: context, at: now))
        #expect(!hasTarget(profile, context: nil, at: now))
        let expired = now.addingTimeInterval(90 * 86_400)
        #expect(!hasTarget(profile, context: context, at: expired))
        var pruned = profile
        pruned.prune(now: expired)
        #expect(!pruned.ranking(for: "aa", now: expired, context: context).hasWholePreferences)
        profile.remove(id: try #require(profile.entries.first?.id))
        #expect(!profile.ranking(for: "aa", now: now, context: context).hasWholePreferences)
        #expect(!hasTarget(profile, context: context, at: now))
    }

    @Test func canonicalPrefixAlternativesUseDistinctPresentationSlots() {
        let entries = ["豈", "\u{f900}", "é", "e\u{301}"].map { PinyinLexiconEntry(syllables: ["a"], text: $0) }
            + [PinyinLexiconEntry(syllables: ["b"], text: "吧")]
        let candidates = PinyinDecoder(entries: entries).compositionCandidates(for: "aab", languages: [.simplifiedChinese])
        let prefixes = candidates.filter { $0.consumedInputCount == 2 }
        #expect(prefixes.map(\.text) == ["éé", "é豈"])
        #expect(Set(prefixes.map(\.id)).count == prefixes.count)
    }

    @Test func personalPrefixProjectionsKeepTheirLearningAndContextExclusions() throws {
        let text = "Synthetic private phrase"
        let dictionary = try UserDictionary(entries: [UserPhrase(input: "aa", text: text, language: .simplifiedChinese)])
        var profile = LearningProfile(entries: [
            LearnedPreference(input: "aa", text: text, language: .simplifiedChinese, strength: 8, lastUsed: now),
        ], now: now)
        let decoder = PinyinDecoder(entries: [PinyinLexiconEntry(syllables: ["a"], text: "字"),
                                               PinyinLexiconEntry(syllables: ["b"], text: "吧")])
        let candidates = decoder.compositionCandidates(for: "aab", languages: [.simplifiedChinese], dictionary: dictionary,
                                                       learning: profile, now: now)
        let prefix = try #require(candidates.first { $0.text == text && $0.consumedInputCount == 2 })
        #expect(prefix.isUserPhrase && !prefix.canLearn)
        #expect(prefix.tokenLearningBonus == 0)
        #expect(profile.bonus(for: prefix, input: "aa", now: now) == 0)
        #expect(CandidateContext(candidate: prefix) == nil)
        let recorded = profile.record(InputCommit(input: "aa", candidate: prefix, reason: .explicitSelection), now: now)
        #expect(!recorded && profile.entries.count == 1)
    }

    @Test func aliasNormalizationKeepsExplicitPrefixBoundariesAndSourceOffsets() throws {
        let decoder = PinyinDecoder(entries: [PinyinLexiconEntry(syllables: ["lv"], text: "绿"),
                                               PinyinLexiconEntry(syllables: ["lv"], text: "吕", score: 99),
                                               PinyinLexiconEntry(syllables: ["b"], text: "吧")])
        var profile = LearningProfile()
        let target = InputCandidate(text: "吕", language: .simplifiedChinese, score: 99)
        for _ in 0..<8 { profile.record(InputCommit(input: "LÜ'", candidate: target, reason: .explicitSelection), now: now) }
        for (input, consumed, expected) in [("lu:'b", 4, "吕"), ("LÜ'b", 3, "吕"), ("lu:b", 3, "绿")] {
            let candidates = decoder.compositionCandidates(for: input, languages: [.simplifiedChinese], learning: profile, now: now)
            #expect(candidates.first { $0.consumedInputCount == consumed }?.text == expected)
        }
    }

    private func fixture(includingSuffix: Bool = false) -> (PinyinDecoder, InputCandidate) {
        var entries = (0..<24).map {
            PinyinLexiconEntry(syllables: ["a"], text: String(UnicodeScalar(0x4e00 + $0)!), score: 100 - $0)
        }
        if includingSuffix { entries.append(PinyinLexiconEntry(syllables: ["b"], text: "吧")) }
        return (PinyinDecoder(entries: entries), InputCandidate(text: entries[0].text + entries[23].text,
                                                              language: .simplifiedChinese, score: 90))
    }
}
