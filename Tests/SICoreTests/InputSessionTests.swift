import Foundation
import Testing
@testable import SICore

struct InputSessionTests {
    @Test func typingAndDelayedResultsKeepTheEntireCompositionUntilManualConfirmation() throws {
        var session = InputSession(candidateGeneration: .deferred)
        session.configure(languages: [.simplifiedChinese])
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        session.append("nihao", now: start)
        let obsolete = try #require(session.pendingCandidateRequest)
        session.append("pengyou", now: start.addingTimeInterval(10))
        let acceptedObsolete = session.accept(obsolete.generate(), now: start.addingTimeInterval(20))
        #expect(!acceptedObsolete)
        let current = try #require(session.pendingCandidateRequest)
        let acceptedCurrent = session.accept(current.generate(), now: start.addingTimeInterval(30))
        #expect(acceptedCurrent)
        #expect(session.buffer == "nihaopengyou")
        #expect(session.cursor == session.buffer.count)
        let prefix = try #require(session.candidates.first { $0.text == "你好" && $0.isPartial })
        let commit = session.commitResult(prefix, reason: .explicitSelection)
        #expect(commit.text == "你好" && commit.input == "nihao")
        #expect(commit.remainingInput == "pengyou" && session.buffer == "pengyou")
        let remainder = try #require(session.pendingCandidateRequest)
        let acceptedRemainder = session.accept(remainder.generate())
        #expect(acceptedRemainder)
        let friend = try #require(session.candidates.first { $0.text == "朋友" && !$0.isPartial })
        #expect(session.commit(friend) == "朋友")
        #expect(session.buffer.isEmpty)
    }

    @Test func selectedCandidateCommitsAndClearsComposition() throws {
        var session = InputSession()
        session.append("nihao")
        let candidate = try #require(session.candidates.first { $0.text == "你好" })
        #expect(session.commit(candidate) == "你好")
        #expect(session.buffer.isEmpty)
        #expect(session.candidates.isEmpty)
    }

    @Test func literalCommitPreservesOriginalCase() {
        var session = InputSession()
        session.append("MySwiftType")
        #expect(session.commit() == "MySwiftType")
        #expect(session.buffer.isEmpty)
    }

    @Test func languageChangesRefreshCurrentComposition() {
        var session = InputSession()
        session.append("shi")
        session.configure(languages: [.english])
        #expect(session.buffer == "shi")
        #expect(session.candidates.allSatisfy { $0.language != .simplifiedChinese })
        session.configure(languages: Set(InputLanguage.allCases))
        #expect(session.candidates.contains { $0.text == "是" })
    }

    @Test func backspaceRefreshesCandidatesAndHandlesEmptyBuffer() {
        var session = InputSession()
        session.deleteBackward()
        session.append("shix")
        session.deleteBackward()
        #expect(session.buffer == "shi")
        #expect(session.candidates.contains { $0.text == "是" })
        session.reset()
        session.deleteBackward()
        #expect(session.buffer.isEmpty)
        #expect(session.candidates.isEmpty)
    }

    @Test func staleCandidateCannotReplaceCurrentInput() throws {
        var session = InputSession()
        session.append("nihao")
        let stale = try #require(session.candidates.first { $0.text == "你好" })
        session.reset()
        session.append("hello")
        #expect(session.commit(stale) == "hello")
    }

    @Test func mixedLanguageCommitsDoNotRequireModeChanges() throws {
        var session = InputSession()
        session.append("nihao")
        let chinese = try #require(session.candidates.first { $0.text == "你好" })
        let first = session.commit(chinese)
        session.append("world")
        let english = try #require(session.candidates.first { $0.language == .english && $0.text == "world" })
        #expect(first + session.commit(english) == "你好world")
    }
}
