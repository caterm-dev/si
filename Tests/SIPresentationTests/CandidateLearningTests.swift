import Testing
import SICore
@testable import SIPresentation

@MainActor
struct CandidateLearningTests {
    @Test func firstChoiceIsNeutralForNumbersMouseAndNavigationBackToTheFirstChoice() throws {
        let words = (0..<16).map { InputCandidate(text: "word\($0)", language: .english, score: 100 - $0, lexicalTokenCount: 1) }
        var selection = CandidateSelection()
        selection.update(words)
        #expect(selection.confirmationReason(for: selection.selected) == .defaultAcceptance)
        #expect(selection.confirmationReason(for: selection.candidate(number: 1)) == .defaultAcceptance)
        #expect(selection.confirmationReason(for: words[0]) == .defaultAcceptance)
        selection.navigate(.column(1))
        #expect(selection.confirmationReason(for: selection.selected) == .explicitSelection)
        selection.navigate(.column(-1))
        #expect(selection.confirmationReason(for: selection.selected) == .defaultAcceptance)
        selection.navigate(.page(1))
        #expect(selection.confirmationReason(for: selection.candidate(number: 1)) == .explicitSelection)
        #expect(selection.confirmationReason(for: nil) == .literal)
    }

    @Test func firstChoiceUsesLanguageAwareIdentity() {
        let english = InputCandidate(text: "he", language: .english, score: 100, lexicalTokenCount: 1)
        let chinese = InputCandidate(text: "he", language: .simplifiedChinese, score: 90, lexicalTokenCount: 1)
        var selection = CandidateSelection()
        selection.update([english, chinese])
        #expect(selection.confirmationReason(for: english) == .defaultAcceptance)
        #expect(selection.confirmationReason(for: chinese) == .explicitSelection)
    }
}

extension CandidateLearningTests {
    @Test func leadingRankedCorrectionIsVisibleAndRequiresAnExplicitChoice() {
        let correction = InputCandidate(text: "你好", language: .simplifiedChinese, score: 100,
                                        isPinyinCorrection: true, modelRankingScore: 2)
        let ordinary = InputCandidate(text: "你好 OA", language: .simplifiedChinese, score: 80,
                                      isMixed: true, lexicalTokenCount: 2, modelRankingScore: 1)
        let literal = InputCandidate(text: "nihoa", language: nil, score: 0)
        var selection = CandidateSelection()
        selection.update([correction, ordinary, literal])
        #expect(selection.candidate(number: 1)?.id == correction.id)
        #expect(selection.selected?.id == ordinary.id)
        #expect(selection.spaceConfirmationReason == .defaultAcceptance)
        selection.move(by: -1)
        #expect(selection.selected?.id == correction.id)
        #expect(selection.spaceConfirmationReason == .explicitSelection)

        let prefixes = ["你", "尼", "泥", "妮", "拟", "逆"].map {
            InputCandidate(text: $0, language: .simplifiedChinese, score: 70,
                           consumedInputCount: 2, lexicalTokenCount: 1)
        }
        selection.update([correction] + prefixes + [literal])
        selection.setExpanded(true)
        #expect(selection.candidate(number: 1)?.id == correction.id)
        #expect(selection.spaceConfirmationReason == .defaultAcceptance)
        #expect(selection.confirmationReason(for: selection.candidate(number: 1)) == .explicitSelection)
    }

    @Test func correctionOnlyResultsInitiallySelectTheOriginalSpelling() {
        let correction = InputCandidate(text: "你好", language: .simplifiedChinese, score: 100,
                                        isPinyinCorrection: true)
        let literal = InputCandidate(text: "nihoa", language: nil, score: 0)
        var selection = CandidateSelection()
        selection.update([correction, literal])
        #expect(selection.selected?.id == literal.id)
        #expect(selection.candidate(number: 1)?.id == correction.id)
        #expect(selection.confirmationReason(for: correction) == .explicitSelection)
        selection.move(by: -1)
        #expect(selection.selected?.id == correction.id)
        #expect(selection.confirmationReason(for: selection.selected) == .explicitSelection)
    }
}
