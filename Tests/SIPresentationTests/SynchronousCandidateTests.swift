import Foundation
import Testing
@testable import SICore
@testable import SIPresentation

@MainActor
struct SynchronousCandidateTests {
    @Test(arguments: ["nihao", "hello"])
    func typingAndDeletionRenderCurrentSelectableCandidatesImmediately(input: String) throws {
        var session = InputSession(engine: CandidateEngine(usesCoverageAdjustedOrder: false))
        session.configure(languages: [.simplifiedChinese, .english])
        var selection = CandidateSelection()
        let view = CandidateListView()
        func verifyCurrentRows() {
            #expect(session.pendingCandidateRequest == nil && !session.hasCandidatePreview)
            selection.update(session.candidates)
            view.render(selection)
            let displayedIDs = selection.displayedRange.map { selection.candidates[$0].id }
            let rowIDs = view.rows.map { $0.candidateID }
            #expect(rowIDs == displayedIDs)
            #expect(view.rows.allSatisfy { $0.isEnabled && !$0.numberLabel.isHidden })
            if session.buffer.isEmpty {
                #expect(view.rows.isEmpty)
            } else {
                #expect(view.rows.first?.isCurrent == true)
            }
            #expect(session.candidates.last?.text == session.buffer || session.buffer.isEmpty)
        }
        for character in input {
            session.append(String(character))
            verifyCurrentRows()
            #expect(session.candidates.contains { !$0.isLiteral })
        }
        let candidate = try #require(selection.candidate(number: 1))
        var clicked: String?
        view.onSelect = { clicked = $0 }
        view.rows[0].performClick(nil)
        #expect(clicked == candidate.id)
        var submitted = session
        #expect(submitted.commitResult(candidate, reason: selection.confirmationReason(for: candidate)).text == candidate.text)
        session.moveCursor(by: -2)
        session.append("a")
        verifyCurrentRows()
        session.deleteForward()
        verifyCurrentRows()
        session.moveToEnd()
        while !session.buffer.isEmpty {
            session.deleteBackward()
            verifyCurrentRows()
        }
        #expect(view.rows.isEmpty)
        session.append(input)
        verifyCurrentRows()
        #expect(session.candidates.contains { !$0.isLiteral })
        session.configure(languages: [])
        verifyCurrentRows()
        #expect(session.candidates.count == 1 && session.candidates.first?.isLiteral == true)
    }

    @Test func customProvidersRunSynchronouslyOnTheCallingThread() {
        var session = InputSession(engine: CandidateEngine(providers: [ThreadProvider()]))
        session.append("synthetic")
        #expect(session.pendingCandidateRequest == nil)
        #expect(session.candidates.first?.text == "on-main")
    }

    @Test func synchronousCorrectionRemainsSelectableAndTracksSettingChanges() throws {
        let languages: Set<InputLanguage> = [.simplifiedChinese]
        var session = InputSession(engine: CandidateEngine(usesCoverageAdjustedOrder: false))
        session.configure(languages: languages, pinyinCorrectionMode: .conservative)
        session.append("nihoa")
        #expect(session.pendingCandidateRequest == nil)
        var selection = CandidateSelection()
        selection.update(session.candidates)
        let correction = try #require(selection.candidates.first { $0.text == "你好" && $0.isPinyinCorrection })
        #expect(!correction.canLearn)
        var literal = session
        #expect(literal.commitResult(reason: .literal).text == "nihoa")
        var disabled = session
        disabled.configure(languages: languages)
        #expect(disabled.pendingCandidateRequest == nil)
        #expect(disabled.candidates.allSatisfy { !$0.isPinyinCorrection })
        #expect(disabled.candidates.last?.text == "nihoa")

        let commit = session.commitResult(correction, reason: selection.confirmationReason(for: correction))
        #expect(commit.text == "你好" && commit.input == "nihoa" && commit.remainingInput.isEmpty)
        #expect(commit.reason == .explicitSelection)
    }

    private struct ThreadProvider: CandidateProvider {
        let language = InputLanguage.english

        func candidates(for input: String) -> [InputCandidate] {
            [InputCandidate(text: Thread.isMainThread ? "on-main" : "off-main", language: language, score: 100)]
        }
    }
}
