import Testing
import SICore
@testable import SIPresentation

struct UnifiedRankingPresentationTests {
    @Test func EnglishCompletionRemainsVisibleDuringBilingualTypingInBothStages() throws {
        var session = InputSession(candidateGeneration: .deferred)
        session.configure(languages: Set(InputLanguage.allCases))
        session.append("abilit")
        let request = try #require(session.pendingCandidateRequest)
        for result in [request.generatePreview(), request.generate()] {
            let accepted = session.accept(result)
            #expect(accepted)
            var selection = CandidateSelection()
            selection.update(session.candidates)
            for expanded in [false, true] {
                selection.setExpanded(expanded)
                #expect(selection.candidates.prefix(5).contains {
                    $0.text == "ability" && $0.language == .english && !$0.isPartial && $0.hasCompletion
                })
                #expect(selection.candidates.last?.isLiteral == true)
            }
        }
        let ability = try #require(session.candidates.first { $0.text == "ability" && $0.language == .english && !$0.isPartial })
        let commit = session.commitResult(ability, reason: .explicitSelection)
        #expect(commit.text == "ability" && commit.input == "abilit")
    }

    @Test func shortEnglishPrefixCannotTakeTheCompleteEnglishReservation() {
        let prefix = InputCandidate(text: "a", language: .english, score: 100, consumedInputCount: 1)
        let chinese = (0..<40).map { InputCandidate(text: "测试\($0)", language: .simplifiedChinese, score: 99 - $0) }
        let english = InputCandidate(text: "ability", language: .english, score: -10, hasCompletion: true)
        let literal = InputCandidate(text: "abilit", language: nil, score: 0)
        var selection = CandidateSelection()
        selection.update([prefix] + chinese + [english, literal])
        #expect(selection.candidates.count == CandidateSelection.maximumCandidates)
        #expect(selection.candidates.contains { $0.id == english.id })
        #expect(selection.candidates.contains { $0.id == literal.id })
        #expect(selection.candidates.contains { $0.id == chinese[0].id })
    }
}
