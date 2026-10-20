import Foundation
import Testing
@testable import SICore

struct EnglishSentenceTests {
    @Test func continuousEnglishWordsProduceASpacedCandidate() {
        let engine = CandidateEngine()
        for languages: Set<InputLanguage> in [[.english], Set(InputLanguage.allCases)] {
            for input in ["iwanttobuild", "i'want'to'build"] {
                let candidates = engine.candidates(for: input, languages: languages)
                #expect(candidates.first?.text == "I want to build")
                #expect(candidates.first?.language == .english && candidates.first?.isMixed == false)
                #expect(candidates.last?.text == input && candidates.last?.isLiteral == true)
                #expect(candidates == engine.candidates(for: input, languages: languages))
            }
        }
        #expect(!engine.candidates(for: "iwanttobuild", languages: [.simplifiedChinese])
            .contains { $0.text == "I want to build" })
    }

    @Test func previewAndConfirmationKeepEnglishWordSpacing() throws {
        var session = InputSession(candidateGeneration: .deferred)
        session.append("iwanttobuild")
        let request = try #require(session.pendingCandidateRequest)
        #expect(session.accept(request.generatePreview()) == true)
        #expect(session.candidates.first?.text == "I want to build")
        session.resolveCandidates()
        let candidate = try #require(session.candidates.first { $0.text == "I want to build" })
        #expect(candidate.appendsSpaceOnAcceptance)
        #expect(session.commit(candidate) == "I want to build")
        #expect(session.buffer.isEmpty)
    }

    @Test func exactWordsMixedTextAndMissingLettersAreNotRewritten() {
        let engine = CandidateEngine()
        let languages = Set(InputLanguage.allCases)
        #expect(engine.candidates(for: "build", languages: languages).first?.text == "build")
        #expect(engine.candidates(for: "nihaoworld", languages: languages)
            .contains { $0.text == "你好world" && $0.isMixed })
        #expect(engine.candidates(for: "helloworldzhongwen", languages: languages)
            .contains { $0.text == "helloworld中文" && $0.isMixed })
        let misspelled = engine.candidates(for: "iwantobuild", languages: languages)
        #expect(!misspelled.contains { $0.text == "I want to build" })
        #expect(misspelled.last?.text == "iwantobuild" && misspelled.last?.isLiteral == true)
    }

    @Test func otherSentencesCasingAndFinalWordCompletionUseTheSameSearch() {
        let engine = CandidateEngine()
        for (input, expected) in [("iliketowrite", "I like to write"), ("openthefile", "open the file"),
                                  ("helloworld", "hello world"), ("IWANTTOBUILD", "I WANT TO BUILD")] {
            #expect(engine.candidates(for: input, languages: Set(InputLanguage.allCases)).first?.text == expected)
        }
        let completion = engine.candidates(for: "iwanttobuil", languages: [.english])
        #expect(completion.contains { $0.text == "I want to build" && $0.hasCompletion && !$0.isPartial })
    }

    @Test func spacedPrefixCommitsOnlyItsSourceAndLearningKeepsOneAggregate() throws {
        var session = InputSession()
        session.append("i'want'to'buildnihao")
        let prefix = try #require(session.candidates.first {
            $0.text == "I want to build" && $0.isPartial
        })
        let commit = session.commitResult(prefix, reason: .explicitSelection)
        #expect(commit.text == "I want to build" && commit.input == "i'want'to'build")
        #expect(commit.remainingInput == "nihao" && session.buffer == "nihao")
        #expect(session.candidates.first?.text == "你好")

        let now = Date(timeIntervalSince1970: 1_790_000_000)
        var learning = LearningProfile()
        #expect(learning.record(commit, now: now) == true)
        #expect(learning.entries.count == 1)
        #expect(learning.entries.first?.input == "i'want'to'build")
        #expect(learning.entries.first?.text == "I want to build")
    }
}
