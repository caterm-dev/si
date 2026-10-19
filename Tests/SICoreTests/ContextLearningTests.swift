import Foundation
import Testing
@testable import SICore

struct ContextLearningTests {
    @Test func previousWordChangesRankingWithoutChangingAvailableCandidates() throws {
        let engine = CandidateEngine()
        let languages = Set(InputLanguage.allCases)
        let file = InputCandidate(text: "file", language: .english, score: 85)
        let find = InputCandidate(text: "find", language: .english, score: 85)
        let open = try context("open")
        let search = try context("search")
        var profile = LearningProfile()
        profile.record(InputCommit(input: "fi", candidate: file, reason: .explicitSelection, context: open), learnContext: true)
        profile.record(InputCommit(input: "fi", candidate: find, reason: .explicitSelection, context: search), learnContext: true)
        let afterOpen = engine.candidates(for: "fi", languages: languages, learning: profile, context: open)
        let afterSearch = engine.candidates(for: "fi", languages: languages, learning: profile, context: search)
        #expect(afterOpen.first?.text == "file")
        #expect(afterSearch.first?.text == "find")
        #expect(Set(afterOpen.map(\.id)) == Set(afterSearch.map(\.id)))
        #expect(afterOpen.last?.isLiteral == true)
        #expect(profile.entries.count == 4)
    }

    @Test func contextualStorageRequiresExplicitOptInAndDeletionIsIndependent() throws {
        let now = Date.now
        let file = InputCandidate(text: "file", language: .english, score: 85)
        let open = try context("open")
        let commit = InputCommit(input: "fi", candidate: file, reason: .explicitSelection, context: open)
        var profile = LearningProfile()
        profile.record(commit, now: now)
        #expect(profile.entries.count == 1)
        #expect(profile.entries.first?.context == nil)
        profile.record(commit, now: now, learnContext: true)
        let contextualEntry = try #require(profile.entries.first { $0.context != nil })
        #expect(profile.bonus(for: file, input: "fi", now: now, context: open) > profile.bonus(for: file, input: "fi", now: now))
        profile.remove(id: contextualEntry.id)
        #expect(profile.bonus(for: file, input: "fi", now: now, context: open) == profile.bonus(for: file, input: "fi", now: now))
        profile.removeAll()
        #expect(profile.entries.isEmpty)
    }

    @Test func contextsAreClientLocalAndDoNotReadOtherSessions() throws {
        var first = try sessionAfterOpen()
        first.append("fi")
        let firstFile = try #require(first.candidates.first { $0.text == "file" })
        let commit = first.commitResult(firstFile, reason: .explicitSelection)
        #expect(commit.context?.text == "open")
        var second = InputSession()
        second.configure(languages: Set(InputLanguage.allCases), usesContext: true)
        second.append("fi")
        let secondFile = try #require(second.candidates.first { $0.text == "file" })
        #expect(second.commitResult(secondFile, reason: .explicitSelection).context == nil)
    }

    @Test func cancellationFocusBreakAndSettingsChangesClearContext() throws {
        for action in 0..<5 {
            var session = try sessionAfterOpen()
            switch action {
            case 0: session.reset()
            case 1: session.breakContext()
            case 2: session.configure(languages: Set(InputLanguage.allCases), usesContext: false)
            case 3: session.configure(languages: [.english], usesContext: true)
            default: session.configure(languages: Set(InputLanguage.allCases), usesContext: true, contextGeneration: 1)
            }
            session.append("fi")
            let file = try #require(session.candidates.first { $0.text == "file" })
            #expect(session.commitResult(file, reason: .explicitSelection).context == nil)
        }
    }

    @Test func expiredOrFutureContextCannotInfluenceNextCommit() throws {
        for offset in [-InputSession.contextLifetime - 1, InputSession.contextLifetime + 1] {
            var session = try sessionAfterOpen(at: .now.addingTimeInterval(offset))
            session.append("fi")
            let file = try #require(session.candidates.first { $0.text == "file" })
            #expect(session.commitResult(file, reason: .explicitSelection).context == nil)
        }
    }

    @Test func literalAndPersonalPhraseCommitsDoNotBecomeContext() throws {
        var literalSession = try sessionAfterOpen()
        literalSession.append("unknown")
        _ = literalSession.commit()
        literalSession.append("fi")
        let file = try #require(literalSession.candidates.first { $0.text == "file" })
        #expect(literalSession.commitResult(file, reason: .explicitSelection).context == nil)

        let privatePhrase = InputCandidate(text: "Synthetic Private Name", language: .english, score: 115, isUserPhrase: true)
        #expect(CandidateContext(candidate: privatePhrase) == nil)
        #expect(CandidateContext(candidate: InputCandidate(text: "literal", language: nil, score: 0)) == nil)
        let dictionary = try UserDictionary(entries: [UserPhrase(input: "sig", text: privatePhrase.text, language: .english)])
        var phraseSession = InputSession()
        phraseSession.configure(languages: [.english], dictionary: dictionary, usesContext: true)
        phraseSession.append("sig")
        let personalPhrase = try #require(phraseSession.candidates.first)
        _ = phraseSession.commitResult(personalPhrase, reason: .explicitSelection)
        phraseSession.append("fi")
        let next = try #require(phraseSession.candidates.first { $0.text == "file" })
        #expect(phraseSession.commitResult(next, reason: .explicitSelection).context == nil)
    }

    @Test func mixedAndSingleLanguagePreferencesHaveDifferentIdentities() {
        let mixed = InputCandidate(text: "你好world", language: .simplifiedChinese, score: 90, isMixed: true)
        let single = InputCandidate(text: mixed.text, language: .simplifiedChinese, score: 90)
        var profile = LearningProfile()
        profile.record(InputCommit(input: "nihaoworld", candidate: mixed, reason: .explicitSelection))
        #expect(profile.bonus(for: mixed, input: "nihaoworld") > 0)
        #expect(profile.bonus(for: single, input: "nihaoworld") == 0)
    }

    private func context(_ text: String) throws -> CandidateContext {
        try #require(CandidateContext(candidate: InputCandidate(text: text, language: .english, score: 110)))
    }

    private func sessionAfterOpen(at date: Date = .now) throws -> InputSession {
        var session = InputSession()
        session.configure(languages: Set(InputLanguage.allCases), usesContext: true)
        session.append("open")
        let open = try #require(session.candidates.first { $0.text == "open" && $0.language == .english })
        _ = session.commitResult(open, reason: .explicitSelection, now: date)
        return session
    }
}
