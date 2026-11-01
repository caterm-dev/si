import Foundation
import Testing
@testable import SICore

struct ApplicationVocabularyLearningTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let word = InputCandidate(text: "食客", language: .simplifiedChinese, score: -100, lexicalTokenCount: 1)

    @Test func firstChoicesCountUsageWithoutCreatingRankingEvidence() throws {
        var memory = ApplicationMemory()
        for _ in 0..<100 {
            let recorded = memory.recordVocabulary(InputCommit(input: "shike", candidate: word, reason: .defaultAcceptance), now: now)

            #expect(recorded)
        }
        let entry = try #require(memory.vocabulary.first)
        #expect(entry.count == 100 && entry.correctionCount == 0 && entry.preference.strength == 0 && entry.lastSelected == nil)
        let snapshot = memory.snapshot(vocabularyEnabled: true, now: now)
        #expect(snapshot.vocabulary.count == 1 && snapshot.learning.entries.isEmpty)
        #expect(snapshot.vocabularyCandidates(for: "shi", languages: [.simplifiedChinese], now: now).isEmpty)
        #expect(snapshot.preferredCandidateID(for: "shike", languages: [.simplifiedChinese]) == nil)
    }

    @Test func oneCorrectionPromotesTheExactSpellingInFullAndProvisionalResultsOnly() throws {
        var memory = ApplicationMemory()
        let recorded = memory.recordVocabulary(InputCommit(input: "shike", candidate: word, reason: .explicitSelection), now: now)

        #expect(recorded)
        let snapshot = memory.snapshot(vocabularyEnabled: true, now: now)
        #expect(snapshot.learning.bonus(for: word, input: "shike", now: now) == 0)
        let leader = InputCandidate(text: "时刻", language: .simplifiedChinese, score: 1_000, lexicalTokenCount: 1)
        let engine = CandidateEngine(providers: [Provider(values: [leader, word])])
        for input in ["shike", "SHIKE", "shi", "shikex", "shi'ke"] {
            var session = InputSession(engine: engine, candidateGeneration: .deferred)
            session.configure(languages: [.simplifiedChinese], learning: snapshot.learning, applicationMemory: snapshot)
            session.append(input, now: now)
            let request = try #require(session.pendingCandidateRequest)
            for result in [request.generatePreview(), request.generate()] {
                if ["shike", "SHIKE"].contains(input) {
                    #expect(result.candidates.first?.id == word.id)
                } else {
                    #expect(snapshot.preferredCandidateID(for: input, languages: [.simplifiedChinese]) == nil)
                    // Custom providers have no provisional search contract; final results still use base ranking.
                    if !result.isPreview { #expect(result.candidates.first?.id == leader.id) }
                }
                #expect(result.candidates.last?.isLiteral == true && result.candidates.last?.text == input)
            }
        }
        #expect(engine.candidates(for: "shike", languages: [], applicationMemory: snapshot).map(\.text) == ["shike"])
    }

    @Test func latestCorrectionWinsWithoutDefaultAcceptanceRefreshingItAndPinsKeepPriority() throws {
        var memory = ApplicationMemory()
        let other = InputCandidate(text: "时刻", language: .simplifiedChinese, score: 500, lexicalTokenCount: 1)
        memory.recordVocabulary(InputCommit(input: "shike", candidate: word, reason: .explicitSelection), now: now)
        memory.recordVocabulary(InputCommit(input: "shike", candidate: other, reason: .explicitSelection), now: now)
        memory.recordVocabulary(InputCommit(input: "shike", candidate: word, reason: .defaultAcceptance), now: now.addingTimeInterval(2))
        let snapshot = memory.snapshot(vocabularyEnabled: true, now: now.addingTimeInterval(2))
        #expect(snapshot.preferredCandidateID(for: "shike", languages: [.simplifiedChinese]) == other.id)
        let pin = InputCandidate(text: "私人短语", language: .simplifiedChinese, score: -1_000,
                                 isUserPhrase: true, isPreferred: true)
        let engine = CandidateEngine(providers: [Provider(values: [word, other, pin])])
        #expect(engine.candidates(for: "shike", languages: [.simplifiedChinese], applicationMemory: snapshot).first?.id == pin.id)
        memory.removeVocabulary(id: try #require(memory.vocabulary.first { $0.preference.text == other.text }?.id))
        #expect(memory.snapshot(vocabularyEnabled: true, now: now).preferredCandidateID(for: "shike", languages: [.simplifiedChinese]) == nil)
        memory.clearVocabulary()
        #expect(memory.snapshot(vocabularyEnabled: true, now: now).vocabulary.isEmpty)
    }

    @Test func prefixSelectionRemembersOnlyConsumedSpellingAndAliasesPreserveSeparators() throws {
        let other = InputCandidate(text: "其他", language: .simplifiedChinese, score: 1_000, lexicalTokenCount: 1)
        let exactPrefix = InputCandidate(text: "绿色", language: .simplifiedChinese, score: -100, consumedInputCount: 6, lexicalTokenCount: 1)
        var session = InputSession(engine: CandidateEngine(providers: [Provider(values: [exactPrefix, other])]))
        session.configure(languages: [.simplifiedChinese])
        session.append("lu:se'hao", now: now)
        let commit = session.commitResult(try #require(session.candidates.first { $0.id == exactPrefix.id }), reason: .explicitSelection, now: now)
        #expect(commit.input == "lu:se'" && session.buffer == "hao")
        var memory = ApplicationMemory()
        let recorded = memory.recordVocabulary(commit, now: now)

        #expect(recorded)
        let snapshot = memory.snapshot(vocabularyEnabled: true, now: now)
        #expect(snapshot.preferredCandidateID(for: "LÜSE'", languages: [.simplifiedChinese]) == "zh-Hans:绿色")
        for input in ["lvse", "lvse'hao", "hao"] {
            #expect(snapshot.preferredCandidateID(for: input, languages: [.simplifiedChinese]) == nil)
        }
    }

    @Test func rewardsAndSelectionsNeverDecayOrExpireAndDeletionStopsTokenEffects() throws {
        var memory = ApplicationMemory()
        for _ in 0..<6 {
            memory.recordVocabulary(InputCommit(input: "shike", candidate: word, reason: .explicitSelection), now: now)
        }
        let later = now.addingTimeInterval(365 * 86_400)
        memory.prune(now: later)
        let snapshot = memory.snapshot(vocabularyEnabled: true, now: later)
        #expect(snapshot.vocabulary.count == 1)
        #expect(abs(snapshot.learning.bonus(for: word, input: "shike", now: later) - 2) < 1e-12)
        #expect(snapshot.learning.tokenBonus(input: "shike", text: word.text, language: .simplifiedChinese, now: later) > 0)
        #expect(snapshot.preferredCandidateID(for: "shike", languages: [.simplifiedChinese]) == word.id)
        memory.removeVocabulary(id: try #require(memory.vocabulary.first?.id))
        let deleted = memory.snapshot(vocabularyEnabled: true, now: later)
        #expect(deleted.learning.tokenBonus(input: "shike", text: word.text, language: .simplifiedChinese, now: later) == 0)
        #expect(deleted.preferredCandidateID(for: "shike", languages: [.simplifiedChinese]) == nil)
    }

    @Test func rewardsRemainBoundedAndExcludedCommitsNeverLearn() {
        var memory = ApplicationMemory()
        for _ in 0..<120 {
            memory.recordVocabulary(InputCommit(input: "shike", candidate: word, reason: .explicitSelection), now: now)
        }
        let snapshot = memory.snapshot(vocabularyEnabled: true, now: now)
        #expect(abs(snapshot.learning.bonus(for: word, input: "shike", now: now) - 32) < 1e-12)
        #expect(snapshot.vocabulary.first?.correctionCount == 120)
        let saved = memory
        for reason: CommitReason in [.literal, .passthrough, .automaticConfirmation] {
            let recorded = memory.recordVocabulary(InputCommit(input: "shike", candidate: word, reason: reason), now: now)

            #expect(!recorded)
        }
        for candidate in [InputCandidate(text: "raw", language: nil, score: 0),
                          InputCandidate(text: "私人", language: .simplifiedChinese, score: 0, isUserPhrase: true),
                          InputCandidate(text: "原文", language: .simplifiedChinese, score: 0, hasLiteralSegments: true),
                          InputCandidate(text: "。", language: .simplifiedChinese, score: 0, punctuationLanguage: .simplifiedChinese)] {
            let recorded = memory.recordVocabulary(InputCommit(input: "shike", candidate: candidate, reason: .explicitSelection), now: now)

            #expect(!recorded)
        }
        #expect(memory == saved)
    }

    @Test func exactChoicesPreserveLanguageIdentityAndMixedLanguageRequirements() {
        var memory = ApplicationMemory()
        let chinese = InputCandidate(text: "he", language: .simplifiedChinese, score: -100, lexicalTokenCount: 1)
        let english = InputCandidate(text: "he", language: .english, score: 100, lexicalTokenCount: 1)
        memory.recordVocabulary(InputCommit(input: "he", candidate: chinese, reason: .explicitSelection), now: now)
        let snapshot = memory.snapshot(vocabularyEnabled: true, now: now)
        let engine = CandidateEngine(providers: [Provider(values: [chinese, english])])
        let bilingual = engine.candidates(for: "he", languages: Set(InputLanguage.allCases), applicationMemory: snapshot)
        #expect(bilingual.first?.id == chinese.id && bilingual.contains { $0.id == english.id })
        #expect(engine.candidates(for: "he", languages: [.english], applicationMemory: snapshot).first?.id == english.id)
        let mixed = InputCandidate(text: "你好 world", language: .simplifiedChinese, score: -100, isMixed: true)
        memory.recordVocabulary(InputCommit(input: "nihaoworld", candidate: mixed, reason: .explicitSelection), now: now)
        let mixedSnapshot = memory.snapshot(vocabularyEnabled: true, now: now)
        #expect(mixedSnapshot.preferredCandidateID(for: "nihaoworld", languages: [.simplifiedChinese]) == nil)
        #expect(mixedSnapshot.preferredCandidateID(for: "nihaoworld", languages: Set(InputLanguage.allCases)) == mixed.id)
    }

    @Test func capacityEvictionRemovesTheOldestSelectionAndItsTokenEvidence() {
        let old = ApplicationVocabularyEntry(
            preference: LearnedPreference(input: "shike", text: word.text, language: .simplifiedChinese,
                                          strength: 1, lastUsed: now),
            count: 3, baseScore: -100, lexicalTokenCount: 1, correctionCount: 3, lastSelected: now)
        let recent = (0..<ApplicationMemory.maximumVocabularyEntries).map { index in
            ApplicationVocabularyEntry(
                preference: LearnedPreference(input: "word", text: "Synthetic \(index)", language: .english,
                                              strength: 0, lastUsed: now.addingTimeInterval(1)),
                count: 1, baseScore: 0, lexicalTokenCount: 1)
        }
        let memory = ApplicationMemory(vocabulary: [old] + recent, now: now.addingTimeInterval(1))
        #expect(memory.vocabulary.count == ApplicationMemory.maximumVocabularyEntries)
        #expect(!memory.vocabulary.contains { $0.id == old.id })
        let snapshot = memory.snapshot(vocabularyEnabled: true, now: now.addingTimeInterval(1))
        #expect(snapshot.preferredCandidateID(for: "shike", languages: [.simplifiedChinese]) == nil)
        #expect(snapshot.learning.tokenBonus(input: "shike", text: word.text, language: .simplifiedChinese, now: now) == 0)
    }

    private struct Provider: CandidateProvider {
        let values: [InputCandidate]
        var language: InputLanguage { .simplifiedChinese }
        var requiredLanguages: Set<InputLanguage> { [] }
        func candidates(for input: String) -> [InputCandidate] { values }
    }
}
