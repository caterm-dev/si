import Testing
@testable import SICore

struct InputSessionTests {
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
