import Foundation
import Testing
@testable import SICore

struct ApplicationVocabularyLearningTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let app = "org.example.synthetic-editor"
    private let word = InputCandidate(text: "食客", language: .simplifiedChinese, score: -10, lexicalTokenCount: 1)

    @Test func firstChoicesCountUsageWithoutCreatingRankingEvidence() throws {
        var memory = ApplicationMemory()
        for _ in 0..<100 {
            let recorded = memory.recordVocabulary(InputCommit(input: "shike", candidate: word, reason: .defaultAcceptance),
                                                    applicationID: app, now: now)
            #expect(recorded)
        }
        let entry = try #require(memory.vocabulary.first)
        #expect(entry.count == 100 && entry.correctionCount == 0 && entry.preference.strength == 0)
        let snapshot = memory.snapshot(applicationID: app, vocabularyEnabled: true, now: now)
        #expect(snapshot.vocabulary.count == 1 && snapshot.learning.entries.isEmpty)
        #expect(snapshot.vocabularyCandidates(for: "shi", languages: [.simplifiedChinese], now: now).isEmpty)
        #expect(snapshot.learning.bonus(for: word, input: "shike", now: now) == 0)
        #expect(snapshot.learning.tokenBonus(input: "shike", text: word.text, language: .simplifiedChinese, now: now) == 0)
    }

    @Test func repeatedCorrectionsRaiseTheBonusOnePointAtATime() throws {
        var memory = ApplicationMemory()
        for correction in 1...12 {
            let recorded = memory.recordVocabulary(InputCommit(input: "shike", candidate: word, reason: .explicitSelection),
                                                    applicationID: app, now: now)
            #expect(recorded)
            let snapshot = memory.snapshot(applicationID: app, vocabularyEnabled: true, now: now)
            let expected = Double(correction / 3)
            #expect(abs(snapshot.learning.bonus(for: word, input: "shike", now: now) - expected) < 1e-12)
            #expect(snapshot.vocabulary.first?.correctionCount == correction)
            #expect(snapshot.vocabularyCandidates(for: "shi", languages: [.simplifiedChinese], now: now).isEmpty == (correction < 3))
            // First-choice confirmations neither trigger the next step nor strengthen an existing step.
            for _ in 0..<4 {
                memory.recordVocabulary(InputCommit(input: "shike", candidate: word, reason: .defaultAcceptance),
                                        applicationID: app, now: now)
            }
            #expect(memory.vocabulary.first?.count == correction * 5)
            #expect(memory.snapshot(applicationID: app, vocabularyEnabled: true, now: now).learning == snapshot.learning)
        }
    }

    @Test func firstChoicesDoNotRefreshDecayedStrengthAndDeletionStopsTokenEffects() throws {
        var memory = ApplicationMemory()
        for _ in 0..<6 {
            memory.recordVocabulary(InputCommit(input: "shike", candidate: word, reason: .explicitSelection),
                                    applicationID: app, now: now)
        }
        let later = now.addingTimeInterval(14 * 86_400)
        let before = memory.snapshot(applicationID: app, vocabularyEnabled: true, now: later).learning
        let bonus = before.bonus(for: word, input: "shike", now: later)
        #expect(bonus > 0 && bonus < 2)
        for _ in 0..<100 {
            memory.recordVocabulary(InputCommit(input: "shike", candidate: word, reason: .defaultAcceptance),
                                    applicationID: app, now: later)
        }
        let after = memory.snapshot(applicationID: app, vocabularyEnabled: true, now: later).learning
        #expect(abs(after.bonus(for: word, input: "shike", now: later) - bonus) < 1e-12)
        #expect(abs(after.tokenBonus(input: "shike", text: word.text, language: .simplifiedChinese, now: later) - bonus) < 1e-12)
        #expect(memory.snapshot(applicationID: "org.example.other", vocabularyEnabled: true, now: later).learning.entries.isEmpty)
        memory.removeVocabulary(id: try #require(memory.vocabulary.first?.id))
        #expect(memory.snapshot(applicationID: app, vocabularyEnabled: true, now: later).learning.entries.isEmpty)
    }

    @Test func correctionRewardsRemainCappedAndRetainOnlyAggregateCounts() throws {
        var memory = ApplicationMemory()
        for _ in 0..<120 {
            memory.recordVocabulary(InputCommit(input: "shike", candidate: word, reason: .explicitSelection),
                                    applicationID: app, now: now)
        }
        let snapshot = memory.snapshot(applicationID: app, vocabularyEnabled: true, now: now)
        #expect(abs(snapshot.learning.bonus(for: word, input: "shike", now: now) - 32) < 1e-12)
        #expect(snapshot.vocabulary.count == 1 && snapshot.vocabulary.first?.count == 120)
        #expect(snapshot.vocabulary.first?.correctionCount == 120)
    }
}
