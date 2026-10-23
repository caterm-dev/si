import Foundation
import Testing
@testable import SICore

struct PartialCommitTests {
    @Test func frequentShortWordsCompeteByConsumedSpellingScoreWithCompleteCompositions() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        var profile = LearningProfile()
        let you = InputCandidate(text: "你", language: .simplifiedChinese, score: 100)
        for _ in 0..<100 { profile.record(InputCommit(input: "ni", candidate: you, reason: .explicitSelection), now: now) }
        let candidates = CandidateEngine().candidates(for: "nihaopengyou", languages: [.simplifiedChinese], learning: profile, now: now)
        #expect(candidates.contains { $0.text == "你好朋友" && !$0.isPartial })
        let ranked = candidates.dropLast()
        for (left, right) in zip(ranked, ranked.dropFirst()) {
            let leftInput = left.consumedInputCount.map { String("nihaopengyou".prefix($0)) } ?? "nihaopengyou"
            let rightInput = right.consumedInputCount.map { String("nihaopengyou".prefix($0)) } ?? "nihaopengyou"
            #expect(profile.rankingScore(for: left, input: leftInput, now: now, context: nil)
                >= profile.rankingScore(for: right, input: rightInput, now: now, context: nil))
        }
    }

    @Test func confirmedPrefixIsRemovedExactlyOnceAndRemainderStaysEditable() throws {
        var session = InputSession()
        session.configure(languages: [.simplifiedChinese])
        session.append("nihaopengyou")
        let prefix = try #require(session.candidates.first { $0.text == "你好" && $0.consumedInputCount == 5 })
        let commit = session.commitResult(prefix, reason: .explicitSelection)
        #expect(commit.input == "nihao")
        #expect(commit.text == "你好")
        #expect(commit.remainingInput == "pengyou")
        #expect(session.buffer == "pengyou")
        #expect(session.cursor == session.buffer.count)
        let friend = try #require(session.candidates.first { $0.text == "朋友" && !$0.isPartial })
        #expect(commit.text + session.commit(friend) == "你好朋友")
        #expect(session.buffer.isEmpty && session.cursor == 0)
    }

    @Test func sourceOffsetsHandleApostrophesAndNormalizedUmlauts() throws {
        for (input, prefixText, count, remainder) in [("Ni'Hao'World", "你好", 7, "World"),
                                                      ("lu:'world", "绿", 4, "world")] {
            var session = InputSession()
            session.append(input)
            let prefix = try #require(session.candidates.first { $0.text == prefixText && $0.consumedInputCount == count })
            let commit = session.commitResult(prefix, reason: .explicitSelection)
            #expect(commit.input == String(input.prefix(count)))
            #expect(commit.remainingInput == remainder)
            #expect(session.buffer == remainder)
        }
    }

    @Test func learningUsesOnlyTheConfirmedCodeAndNeverTheUncommittedRemainder() throws {
        var session = InputSession()
        session.append("nihaopengyou")
        let prefix = try #require(session.candidates.first { $0.text == "你好" && $0.consumedInputCount == 5 })
        let commit = session.commitResult(prefix, reason: .explicitSelection)
        var profile = LearningProfile()
        profile.record(commit)
        #expect(profile.entries.count == 1)
        #expect(profile.entries.first?.input == "nihao")
        #expect(!profile.entries.contains { $0.input.contains("pengyou") })
        let whole = InputCandidate(text: "你好", language: .simplifiedChinese, score: 100)
        #expect(profile.bonus(for: whole, input: "nihao") > 0)
    }

    @Test func returnAndCancellationPreserveOrDiscardTheRemainingLiteralExactly() throws {
        var session = InputSession()
        session.append("nihaopengyou")
        let prefix = try #require(session.candidates.first { $0.text == "你好" && $0.consumedInputCount == 5 })
        _ = session.commit(prefix)
        session.moveToStart()
        session.append("X")
        #expect(session.commit() == "Xpengyou")
        session.append("nihaopengyou")
        session.reset()
        #expect(session.buffer.isEmpty && session.candidates.isEmpty)
    }

    @Test func prefixSelectionIsRejectedAfterItsSourceHasBeenEditedAway() throws {
        var session = InputSession()
        session.append("nihaopengyou")
        let old = try #require(session.candidates.first { $0.text == "你好" && $0.isPartial })
        session.moveToStart()
        session.deleteForward()
        let edited = session.buffer
        #expect(session.commit(old) == edited)
        #expect(session.buffer.isEmpty)
    }
}
