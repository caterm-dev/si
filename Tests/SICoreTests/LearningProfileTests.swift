import Foundation
import Testing
@testable import SICore

struct LearningProfileTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let engine = CandidateEngine()
    private let languages = Set(InputLanguage.allCases)

    @Test func preparedRankingMatchesOrdinaryRankingAcrossIdentitiesAndKeepsValueSnapshots() throws {
        let previous = try #require(CandidateContext(candidate: candidate("你好")))
        let words = [candidate("吕"), InputCandidate(text: "file", language: .english, score: 85),
                     InputCandidate(text: "你好world", language: .simplifiedChinese, score: 90, isMixed: true)]
        var profile = LearningProfile()
        for (input, word) in zip(["lv", "fi", "nihaoworld"], words) {
            profile.record(InputCommit(input: input, candidate: word, reason: .explicitSelection, context: previous),
                           now: now, learnContext: true)
        }
        let other = [InputCandidate(text: "private", language: .simplifiedChinese, score: 115, isUserPhrase: true),
                     InputCandidate(text: "字QwErTy", language: .simplifiedChinese, score: 80, isMixed: true, hasLiteralSegments: true),
                     InputCandidate(text: "literal", language: nil, score: 0),
                     InputCandidate(text: "字", language: .simplifiedChinese, score: 90, tokenLearningBonus: 24)]
        for input in ["LÜ", "lu:", "fi", "nihaoworld", "unmatched"] {
            for context in [nil, previous] {
                let prepared = profile.ranking(for: input, now: now, context: context)
                for word in words + other {
                    #expect(prepared.score(word) == profile.rankingScore(for: word, input: input, now: now, context: context))
                }
            }
        }
        #expect(LearningProfile(entries: profile.entries, now: now) == profile)
        let snapshot = profile.ranking(for: "lv", now: now, context: previous)
        profile.removeAll()
        #expect(snapshot.score(words[0]) > words[0].rankingScore)
        let cleared = profile.ranking(for: "lv", now: now, context: previous)
        #expect(!cleared.hasWholePreferences && !cleared.isActive)
        #expect(cleared.score(other[3]) == other[3].rankingScore)
    }

    @Test func phoneticAliasesShareLearningButExplicitBoundariesRemainDistinct() {
        var profile = LearningProfile()
        let green = candidate("绿")
        profile.record(InputCommit(input: "LÜ", candidate: green, reason: .explicitSelection), now: now)
        #expect(profile.bonus(for: green, input: "lv", now: now) > 0)
        #expect(profile.bonus(for: green, input: "lu:", now: now) > 0)
        let city = candidate("西安")
        profile.record(InputCommit(input: "xi'an", candidate: city, reason: .explicitSelection), now: now)
        #expect(profile.bonus(for: city, input: "xi'an", now: now) > 0)
        #expect(profile.bonus(for: city, input: "xian", now: now) == 0)
    }

    @Test func repeatedChoiceChangesRankingWithoutDroppingAlternatives() throws {
        var profile = LearningProfile()
        let original = engine.candidates(for: "shi", languages: languages, now: now)
        let ship = try #require(original.first { $0.text == "ship" })
        for _ in 0..<4 {
            profile.record(InputCommit(input: "shi", candidate: ship, reason: .explicitSelection), now: now)
        }
        let ranked = engine.candidates(for: "shi", languages: languages, learning: profile, now: now)
        #expect(ranked.first?.text == "ship")
        #expect(Set(ranked.map(\.id)) == Set(original.map(\.id)))
        #expect(ranked.last?.text == "shi")
        #expect(ranked.last?.isLiteral == true)
        #expect(ranked == engine.candidates(for: "shi", languages: languages, learning: profile, now: now))
    }

    @Test func defaultAcceptanceDoesNotCreateOrReinforcePreferences() {
        let word = candidate("时")
        var explicit = LearningProfile()
        var implicit = LearningProfile()
        explicit.record(InputCommit(input: "shi", candidate: word, reason: .explicitSelection), now: now)
        for _ in 0..<100 {
            let recorded = implicit.record(InputCommit(input: "shi", candidate: word, reason: .defaultAcceptance), now: now)
            #expect(!recorded)
        }
        #expect(implicit.entries.isEmpty)
        let saved = explicit.entries
        let previous = CandidateContext(candidate: candidate("你好"))
        let recorded = explicit.record(InputCommit(input: "shi", candidate: word, reason: .defaultAcceptance, context: previous),
                                       now: now.addingTimeInterval(60), learnContext: true)
        #expect(!recorded && explicit.entries == saved)
    }

    @Test func literalCancellationAndHostBoundaryCommitsAreNotLearned() {
        var profile = LearningProfile()
        let word = candidate("时")
        for reason in [CommitReason.literal, .focusChange, .passthrough] {
            let learned = profile.record(InputCommit(input: "shi", candidate: word, reason: reason), now: now)
            #expect(!learned)
        }
        let literal = InputCandidate(text: "MySecretToken", language: nil, score: 0)
        let learned = profile.record(InputCommit(input: "MySecretToken", candidate: literal,
                                                 reason: .explicitSelection), now: now)
        #expect(!learned)
        #expect(profile.entries.isEmpty)
    }

    @Test func staleSelectionCannotGenerateLearnableCommit() throws {
        var session = InputSession()
        session.append("shi")
        let stale = try #require(session.candidates.first { $0.text == "是" })
        session.reset()
        session.append("hello")
        let commit = session.commitResult(stale, reason: .explicitSelection)
        var profile = LearningProfile()
        #expect(commit.text == "hello")
        #expect(commit.reason == .literal)
        let learned = profile.record(commit, now: now)
        #expect(!learned)
        #expect(session.buffer.isEmpty && session.candidates.isEmpty)
    }

    @Test func recentUseDecaysAndExpires() {
        var profile = LearningProfile()
        let word = candidate("时")
        profile.record(InputCommit(input: "shi", candidate: word, reason: .explicitSelection), now: now)
        let later = now.addingTimeInterval(14 * 86_400)
        #expect(profile.bonus(for: word, input: "shi", now: later) < profile.bonus(for: word, input: "shi", now: now))
        let expired = now.addingTimeInterval(90 * 86_400)
        #expect(profile.bonus(for: word, input: "shi", now: expired) == 0)
        profile.prune(now: expired)
        #expect(profile.entries.isEmpty)
    }

    @Test func disabledLanguagesAndIndependentCodesStayIsolated() {
        var profile = LearningProfile()
        let word = candidate("时")
        profile.record(InputCommit(input: "SHI", candidate: word, reason: .explicitSelection), now: now)
        #expect(profile.bonus(for: word, input: "shi", now: now) > 0)
        #expect(profile.bonus(for: word, input: "sh", now: now) == 0)
        #expect(engine.candidates(for: "shi", languages: [.english], learning: profile, now: now)
            .allSatisfy { $0.language != .simplifiedChinese })
        #expect(engine.candidates(for: "shi", languages: [], learning: profile, now: now).count == 1)
    }

    @Test func deletingPreferencesRestoresBaseRanking() throws {
        var profile = LearningProfile()
        let word = candidate("时")
        profile.record(InputCommit(input: "shi", candidate: word, reason: .explicitSelection), now: now)
        #expect(engine.candidates(for: "shi", languages: languages, learning: profile, now: now).first?.text == "时")
        profile.remove(id: try #require(profile.entries.first?.id))
        #expect(profile.bonus(for: word, input: "shi", now: now) == 0)
        #expect(engine.candidates(for: "shi", languages: languages, learning: profile, now: now).first?.text == "是")
    }

    @Test func malformedFutureAndExpiredRecordsAreRejected() {
        let entries = [
            record(input: "", strength: 1), record(input: "token123", strength: 1),
            record(input: "shi", strength: -.infinity), record(input: "shi", strength: .nan),
            record(input: "shi", strength: 1_001),
            LearnedPreference(input: "shi", text: "bad\ntext", language: .simplifiedChinese, strength: 1, lastUsed: now),
            LearnedPreference(input: "shi", text: "时", language: .simplifiedChinese,
                              strength: 1, lastUsed: now.addingTimeInterval(1_000)),
            LearnedPreference(input: "shi", text: "时", language: .simplifiedChinese,
                              strength: 1, lastUsed: now.addingTimeInterval(-91 * 86_400)),
        ]
        #expect(LearningProfile(entries: entries, now: now).entries.isEmpty)
    }

    @Test func boundedStoreKeepsNewestEntriesDeterministically() {
        let entries = (0..<(LearningProfile.maximumEntries + 10)).map {
            LearnedPreference(input: "shi", text: "word\($0)", language: .english,
                              strength: 1, lastUsed: now.addingTimeInterval(-Double($0)))
        }
        let profile = LearningProfile(entries: entries, now: now)
        #expect(profile.entries.count == LearningProfile.maximumEntries)
        #expect(profile.entries.first?.text == "word0")
        #expect(!profile.entries.contains { $0.text == "word5009" })
    }

    @Test func repeatedUseHasBoundedInfluence() {
        var profile = LearningProfile()
        let word = candidate("时")
        for _ in 0..<2_000 {
            profile.record(InputCommit(input: "shi", candidate: word, reason: .explicitSelection), now: now)
        }
        #expect(profile.bonus(for: word, input: "shi", now: now) <= 32)
        #expect(profile.entries.first?.strength == 1_000)
        #expect(LearningProfile(entries: profile.entries, now: now) == profile)
    }

    private func candidate(_ text: String) -> InputCandidate {
        InputCandidate(text: text, language: .simplifiedChinese, score: 99)
    }

    private func record(input: String, strength: Double) -> LearnedPreference {
        LearnedPreference(input: input, text: "时", language: .simplifiedChinese, strength: strength, lastUsed: now)
    }
}
