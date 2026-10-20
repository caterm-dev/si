import Foundation
import Testing
@testable import SICore

struct DeferredCandidateTests {
    @Test func currentPreviewUpdatesBeforeFinalSearchWithoutAcceptingOldRevisions() throws {
        var session = InputSession(candidateGeneration: .deferred)
        session.append("ni")
        let first = try #require(session.pendingCandidateRequest)
        let preview = first.generatePreview()
        #expect(preview.isPreview && session.accept(preview))
        #expect(session.hasCandidatePreview && session.pendingCandidateRequest?.id == first.id)
        #expect(session.candidates.contains { $0.text == "你" })
        #expect(session.accept(preview) == false)
        session.append("hao")
        let latest = try #require(session.pendingCandidateRequest)
        #expect(!session.hasCandidatePreview && !session.accept(preview))
        #expect(session.accept(first.generate()) == false)
        let updated = latest.generatePreview()
        #expect(updated.candidates == latest.generatePreview().candidates)
        #expect(session.accept(updated) == true)
        #expect(session.candidates.contains { $0.text == "你好" && !$0.isPartial })
        #expect(session.candidates.last?.text == "nihao" && session.candidates.last?.isLiteral == true)
        let final = latest.generate()
        #expect(session.accept(final) && !session.hasCandidatePreview)
        #expect(session.pendingCandidateRequest == nil && session.candidates == final.candidates)
        #expect(session.accept(updated) == false)
    }

    @Test func previewSelectionResolvesFinalCandidatesAndLiteralCommitNeverWaits() throws {
        var session = InputSession(candidateGeneration: .deferred)
        session.append("nihaopengyou")
        #expect(session.accept(try #require(session.pendingCandidateRequest).generatePreview()) == true)
        let prefix = try #require(session.candidates.first { $0.text == "你好" && $0.isPartial })
        let commit = session.commitResult(prefix, reason: .explicitSelection)
        #expect(commit.text == "你好" && commit.input == "nihao" && session.buffer == "pengyou")
        #expect(!session.hasCandidatePreview)

        var literal = InputSession(engine: CandidateEngine(providers: [NoSynchronousQuery()]), candidateGeneration: .deferred)
        literal.append("ExactSpelling")
        let pending = try #require(literal.pendingCandidateRequest)
        #expect(literal.accept(pending.generatePreview()) == true)
        #expect(literal.commit() == "ExactSpelling")
        #expect(!literal.accept(pending.generatePreview()) && !literal.hasCandidatePreview)
    }

    @Test func previewsPreserveEnabledLanguagesNormalizationAndExactLiteralText() throws {
        for languages: Set<InputLanguage> in [[], [.english], [.simplifiedChinese], Set(InputLanguage.allCases)] {
            for input in ["he", "nihao", "lu:'se", "woaiSwift", "UnknownQzX", "👩🏽‍💻", String(repeating: "a", count: 65)] {
                var session = InputSession(candidateGeneration: .deferred)
                session.configure(languages: languages)
                session.append(input)
                let request = try #require(session.pendingCandidateRequest)
                #expect(session.accept(request.generatePreview()) == true)
                #expect(session.candidates.last?.text == input && session.candidates.last?.isLiteral == true)
                #expect(session.candidates.allSatisfy { $0.language.map(languages.contains) ?? true })
                #expect(!session.candidates.contains { $0.isMixed } || languages == Set(InputLanguage.allCases))
                if input == "he", languages == Set(InputLanguage.allCases) {
                    #expect(session.candidates.contains { $0.language == .english && $0.text == "he" })
                    #expect(session.candidates.contains { $0.language == .simplifiedChinese && $0.text == "和" })
                }
                if input == "lu:'se", languages.contains(.simplifiedChinese) {
                    let prefix = try #require(session.candidates.first { $0.text == "绿" && $0.isPartial })
                    #expect(prefix.consumedInputCount == 4)
                }
            }
        }
    }

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
        let request = try #require(first.pendingCandidateRequest)
        let result = request.generate()
        let preview = request.generatePreview()
        var other = InputSession(candidateGeneration: .deferred)
        other.append("nihao")
        #expect(other.accept(result) == false)
        #expect(other.accept(preview) == false)
        first.reset()
        first.append("nihao")
        #expect(first.accept(result) == false)
        #expect(first.accept(preview) == false)
        let current = try #require(first.pendingCandidateRequest).generate()
        #expect(first.commit() == "nihao")
        #expect(first.accept(current) == false)
        #expect(first.buffer.isEmpty && first.candidates.isEmpty)
    }

    @Test func deletingLastCharacterClearsPreviewAndPersonalHintsKeepLearningExclusions() throws {
        var session = InputSession(candidateGeneration: .deferred)
        session.append("a")
        #expect(session.accept(try #require(session.pendingCandidateRequest).generatePreview()) == true)
        session.deleteBackward()
        #expect(session.buffer.isEmpty && !session.hasCandidatePreview && session.pendingCandidateRequest == nil)
        let dictionary = try UserDictionary(entries: [UserPhrase(input: "xm", text: "小明", language: .simplifiedChinese)])
        session.configure(languages: [.simplifiedChinese], dictionary: dictionary)
        session.append("woaixm")
        let request = try #require(session.pendingCandidateRequest)
        let preview = request.generatePreview()
        #expect(session.accept(preview) == true)
        let personal = try #require(session.candidates.first { $0.text == "我爱小明" })
        #expect(personal.isUserPhrase && !personal.canLearn)
        session.configure(languages: [.simplifiedChinese])
        #expect(session.accept(preview) == false)
        #expect(session.accept(try #require(session.pendingCandidateRequest).generatePreview()) == true)
        #expect(!session.candidates.contains { $0.isUserPhrase })
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
        let request = try #require(session.pendingCandidateRequest)
        let old = request.generate()
        let preview = request.generatePreview()
        session.configure(languages: languages,
                          learning: change == "learning" || change == "secure" ? LearningProfile() : profile,
                          dictionary: change == "dictionary" || change == "secure" ? UserDictionary() : dictionary,
                          usesContext: true, contextGeneration: change == "context" ? 2 : 1)
        #expect(session.accept(old) == false)
        #expect(session.accept(preview) == false)
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
