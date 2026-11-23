import AppKit
import Testing
import SICore
@testable import SIPresentation

@MainActor
struct CandidateSelectionContentTests {
    private let noncharacter = "\u{10FFFF}"

    @Test func keepsCandidateBytesAndLanguageIdentityRegardlessOfFontCoverage() {
        let chinese = InputCandidate(text: "he", language: .simplifiedChinese, score: 100, lexicalTokenCount: 1)
        let english = InputCandidate(text: "he", language: .english, score: 90, lexicalTokenCount: 1)
        let literal = InputCandidate(text: "original\(noncharacter)", language: nil, score: 0)
        let unusual = [
            InputCandidate(text: noncharacter, language: .simplifiedChinese, score: 150, lexicalTokenCount: 1),
            InputCandidate(text: "词\(noncharacter)", language: .simplifiedChinese, score: 140, consumedInputCount: 2,
                           lexicalTokenCount: 1),
            InputCandidate(text: "personal\(noncharacter)", language: .english, score: 130, isUserPhrase: true),
            InputCandidate(text: "vocabulary\(noncharacter)", language: .english, score: 120, isApplicationVocabulary: true),
        ]
        var selection = CandidateSelection()
        selection.update(unusual + [chinese, english, literal])
        #expect(selection.candidates == unusual + [chinese, english, literal])
        #expect(selection.selected == unusual.first)
        #expect(selection.candidate(number: 5) == chinese)
        #expect(selection.candidate(number: 6) == english)
        for (actual, expected) in zip(selection.candidates, unusual + [chinese, english, literal]) {
            #expect(actual.text.utf8.elementsEqual(expected.text.utf8))
        }
        #expect(selection.candidates.last?.text.utf8.elementsEqual(literal.text.utf8) == true)
        selection.update([literal])
        #expect(selection.selected == literal)
        selection.update(unusual)
        #expect(selection.candidates == unusual && selection.selected == unusual.first)
    }

    @Test func reportedSpellingUsesTheSharedShortlistForRenderingNumbersAndMouse() throws {
        for preview in [true, false] {
            var session = InputSession(candidateGeneration: .deferred)
            session.append("heihe")
            let request = try #require(session.pendingCandidateRequest)
            let accepted = session.accept(preview ? request.generatePreview() : request.generate())
            #expect(accepted)
            let engineCandidates = session.candidates
            var selection = CandidateSelection()
            selection.update(engineCandidates)
            #expect(session.candidates == engineCandidates)
            #expect(selection.candidates.contains { $0.text == "黑" && $0.isPartial })
            #expect(selection.candidates.last?.text == "heihe" && selection.candidates.last?.isLiteral == true)
            #expect(selection.candidates == CandidateShortlist.candidates(from: engineCandidates))
            for expanded in [false, true] {
                selection.setExpanded(expanded)
                selection.move(by: -selection.selectedIndex)
                let view = CandidateListView()
                var clicked: String?
                view.onSelect = { clicked = $0 }
                for index in selection.candidates.indices {
                    selection.move(by: index - selection.selectedIndex)
                    let chosen = try #require(selection.selected)
                    let number = index % CandidateSelection.pageSize + 1
                    #expect(selection.candidate(number: number) == chosen)
                    view.render(selection)
                    let row = view.rows[index - selection.displayedRange.lowerBound]
                    #expect(row.candidateLabel.stringValue.utf8.elementsEqual(chosen.text.utf8))
                    #expect(row.numberLabel.stringValue == String(number))
                    row.performClick(nil)
                    #expect(clicked == chosen.id)
                }
            }
            let prefix = try #require(selection.candidates.first { $0.text == "黑" && $0.isPartial })
            let commit = session.commitResult(prefix, reason: .explicitSelection)
            #expect(commit.text == "黑" && commit.input == "hei" && session.buffer == "he")
        }
    }
}
