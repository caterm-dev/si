import Foundation
import Testing
@testable import SICore

struct RustConversionIntegrationTests {
    @Test func sharedEngineReturnsBothLanguagesAndLiteral() throws {
        _ = try #require(RustConversion.shared)
        let engine = CandidateEngine()
        let both = engine.candidates(for: "he", languages: [.english, .simplifiedChinese])
        #expect(both.contains { $0.text == "he" && $0.language == .english && !$0.hasCompletion })
        #expect(both.contains { $0.text == "和" && $0.language == .simplifiedChinese })
        #expect(both.last?.isLiteral == true && both.last?.text == "he")
        let disabled = engine.candidates(for: "Exact_🦉", languages: [])
        #expect(disabled.count == 1 && disabled[0].isLiteral && disabled[0].text == "Exact_🦉")
    }

    @Test func prefixBridgeConsumesOriginalUmlautAndSeparator() throws {
        var session = InputSession()
        session.configure(languages: [.simplifiedChinese])
        session.append("lu:'se")
        let prefix = try #require(session.candidates.first {
            $0.text == "绿" && $0.consumedInputCount == 4
        })
        let commit = session.commitResult(prefix, reason: .explicitSelection)
        #expect(commit.input == "lu:'")
        #expect(commit.text == "绿")
        #expect(session.buffer == "se")
    }

    @Test func personalPhrasesJoinRustPathsAndAreIneligibleForLearning() throws {
        let phrase = try UserPhrase(input: "qxz", text: "小鹿", language: .simplifiedChinese, isPinned: true)
        let dictionary = try UserDictionary(entries: [phrase])
        let engine = CandidateEngine()
        let exact = engine.candidates(for: "qxz", languages: [.simplifiedChinese], dictionary: dictionary)
        #expect(exact.first?.text == "小鹿" && exact.first?.isPreferred == true)
        let sentence = engine.candidates(for: "nihaoqxz", languages: [.simplifiedChinese], dictionary: dictionary,
                                         includesConfirmationEvidence: true)
        let composed = try #require(sentence.first { $0.text == "你好小鹿" && !$0.isPartial })
        #expect(composed.isUserPhrase && !composed.canLearn && composed.confirmationBoundaries.isEmpty)
    }

    @Test func exactChineseAlignmentIsAvailableOnlyWhenRequested() throws {
        let engine = CandidateEngine()
        let input = "ni'hao"
        let normal = try #require(engine.candidates(for: input, languages: [.simplifiedChinese]).first { $0.text == "你好" })
        #expect(normal.confirmationBoundaries.isEmpty)
        let traced = try #require(engine.candidates(for: input, languages: [.simplifiedChinese],
                                                  includesConfirmationEvidence: true).first { $0.text == "你好" })
        #expect(traced.sourceSegmentBoundaries == [3, 6])
        #expect(traced.confirmationBoundaries.contains(ConfirmationBoundary(sourceCount: 3, outputByteCount: 3)))
    }

    @Test func abbreviationAndEnglishSeparatorKeepExactRemainders() throws {
        var session = InputSession()
        session.configure(languages: [.simplifiedChinese])
        session.append("jintjiushi")
        let today = try #require(session.candidates.first { $0.text == "今天" && $0.consumedInputCount == 4 })
        #expect(session.commitResult(today, reason: .explicitSelection).input == "jint")
        #expect(session.buffer == "jiushi")
        session.reset()
        session.configure(languages: [.english])
        session.append("i'want'to'build")
        #expect(session.candidates.contains { $0.text == "I want to build" && !$0.isPartial })
        #expect(session.candidates.last?.text == "i'want'to'build")
    }

    @Test func standaloneWordPreferenceCanRankAConstructedRustPath() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let profile = LearningProfile(entries: [LearnedPreference(
            input: "shike", text: "食客", language: .simplifiedChinese, strength: 8, lastUsed: now
        )], now: now)
        let engine = CandidateEngine()
        let base = engine.candidates(for: "woshike", languages: [.simplifiedChinese], now: now)
        let ranked = engine.candidates(for: "woshike", languages: [.simplifiedChinese], learning: profile, now: now)
        let learned = try #require(ranked.first { $0.text == "我食客" && !$0.isPartial })
        #expect(learned.tokenLearningBonus > 0)
        #expect(ranked.first?.id == learned.id)
        #expect(base.first?.id != learned.id)
    }
}
