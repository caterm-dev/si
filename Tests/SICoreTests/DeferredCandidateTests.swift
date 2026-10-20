import Foundation
import Testing
@testable import SICore

struct DeferredCandidateTests {
    @Test func editsDoNotRunProvidersAndKeepExactSpellingAvailable() {
        let engine = CandidateEngine(providers: [NoSynchronousQuery()])
        var session = InputSession(engine: engine, candidateGeneration: .deferred)
        for letter in "Synthetic" { session.append(String(letter)) }
        session.moveCursor(by: -3)
        session.deleteBackward()
        session.deleteForward()
        session.append("👩🏽‍💻")
        session.configure(languages: [.english])
        #expect(session.pendingCandidateRequest != nil)
        #expect(session.candidates.count == 1)
        #expect(session.candidates.first?.isLiteral == true)
        #expect(session.candidates.first?.text == session.buffer)
        #expect(session.commit() == "Synth👩🏽‍💻ic")
    }

    @Test func editsCancelOldResultsAndFreshResultsApplyOnlyOnce() throws {
        var session = InputSession(candidateGeneration: .deferred)
        session.append("ni")
        let old = try #require(session.pendingCandidateRequest).generate()
        session.append("hao")
        let latest = try #require(session.pendingCandidateRequest).generate()
        #expect(session.accept(old) == false)
        #expect(session.buffer == "nihao")
        #expect(session.accept(latest) == true)
        #expect(session.accept(latest) == false)
        #expect(session.candidates.first?.text == "你好")
    }

    @Test func resetLiteralCommitAndAnotherClientCannotAcceptOldResults() throws {
        var first = InputSession(candidateGeneration: .deferred)
        first.append("nihao")
        let result = try #require(first.pendingCandidateRequest).generate()
        var other = InputSession(candidateGeneration: .deferred)
        other.append("nihao")
        #expect(other.accept(result) == false)
        first.reset()
        first.append("nihao")
        #expect(first.accept(result) == false)
        let current = try #require(first.pendingCandidateRequest).generate()
        #expect(first.commit() == "nihao")
        #expect(first.accept(current) == false)
        #expect(first.buffer.isEmpty && first.candidates.isEmpty)
    }

    @Test func configurationAndConsentChangesInvalidateSnapshots() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        var session = InputSession(candidateGeneration: .deferred)
        session.append("shi")
        let original = try #require(session.pendingCandidateRequest).generate()
        let profile = LearningProfile(entries: [
            LearnedPreference(input: "shi", text: "时", language: .simplifiedChinese, strength: 8, lastUsed: now),
        ], now: now)
        session.configure(languages: [.simplifiedChinese], learning: profile, contextGeneration: 1, now: now)
        #expect(session.accept(original) == false)
        let learned = try #require(session.pendingCandidateRequest).generate()
        session.configure(languages: [.english], contextGeneration: 2, now: now)
        #expect(session.accept(learned) == false)
        session.resolveCandidates()
        #expect(session.candidates.allSatisfy { $0.language != .simplifiedChinese })
        #expect(session.candidates.last?.text == "shi")
    }

    @Test func resolvingBeforeSelectionMatchesSynchronousResultsAndPreservesPrefixes() throws {
        var immediate = InputSession()
        var deferred = InputSession(candidateGeneration: .deferred)
        immediate.append("nihaopengyou")
        deferred.append("nihaopengyou")
        let old = try #require(deferred.pendingCandidateRequest).generate()
        deferred.resolveCandidates()
        #expect(deferred.candidates == immediate.candidates)
        let prefix = try #require(deferred.candidates.first { $0.text == "你好" && $0.consumedInputCount == 5 })
        let commit = deferred.commitResult(prefix, reason: .explicitSelection)
        #expect(commit.text == "你好" && commit.input == "nihao" && commit.remainingInput == "pengyou")
        #expect(deferred.accept(old) == false)
        #expect(deferred.pendingCandidateRequest != nil)
        deferred.resolveCandidates()
        #expect(deferred.candidates.first?.text == "朋友")
    }

    @Test(arguments: ["learning", "dictionary", "context", "secure"])
    func eachSensitiveConfigurationChangeRejectsItsOwnInFlightSnapshot(change: String) throws {
        let profile = LearningProfile(entries: [
            LearnedPreference(input: "probe", text: "Known", language: .english, strength: 1, lastUsed: .now),
        ])
        let dictionary = try UserDictionary(entries: [UserPhrase(input: "probe", text: "Synthetic phrase", language: .english)])
        let languages = Set(InputLanguage.allCases)
        var session = InputSession(engine: CandidateEngine(providers: []), candidateGeneration: .deferred)
        session.configure(languages: languages, learning: profile, dictionary: dictionary, usesContext: true, contextGeneration: 1)
        session.append("probe")
        let old = try #require(session.pendingCandidateRequest).generate()
        session.configure(languages: languages,
                          learning: change == "learning" || change == "secure" ? LearningProfile() : profile,
                          dictionary: change == "dictionary" || change == "secure" ? UserDictionary() : dictionary,
                          usesContext: true, contextGeneration: change == "context" ? 2 : 1)
        #expect(session.accept(old) == false)
        #expect(session.pendingCandidateRequest != nil)
        session.resolveCandidates()
        if change == "dictionary" || change == "secure" {
            #expect(!session.candidates.contains { $0.isUserPhrase })
        }
        #expect(session.candidates.last?.text == "probe")
    }

    @Test func caretEditsDoNotInvalidateCurrentSpellingResults() throws {
        var session = InputSession(candidateGeneration: .deferred)
        session.append("nihao")
        let result = try #require(session.pendingCandidateRequest).generate()
        session.moveCursor(by: -2)
        #expect(session.accept(result) == true)
        #expect(session.cursorUTF16Offset == 3)
        #expect(session.buffer == "nihao")
    }

    private struct NoSynchronousQuery: CandidateProvider {
        let language = InputLanguage.english
        func candidates(for input: String) -> [InputCandidate] {
            Issue.record("Deferred edits must not synchronously query a provider")
            return []
        }
    }
}
