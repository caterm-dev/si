import Testing
import SICore
@testable import SIPresentation

struct CandidateSelectionTests {
    private func candidates(_ count: Int) -> [InputCandidate] {
        (0..<count).map { InputCandidate(text: "word\($0)", language: .english, score: count - $0) }
    }

    @Test func arrowsAndDigitsReferToTheSamePage() throws {
        var selection = CandidateSelection()
        let values = candidates(24)
        selection.update(values)
        #expect(selection.selected == values[0])
        selection.move(by: 1)
        #expect(selection.selected == selection.candidate(number: 2))
        selection.move(by: -1)
        #expect(selection.selected == values[0])
        selection.move(by: 9)
        #expect(selection.page == 1)
        #expect(selection.visibleRange == 9..<18)
        #expect(selection.candidate(number: 2) == values[10])
        selection.movePage(by: 1)
        #expect(selection.selected == values[18])
        #expect(selection.candidate(number: 6) == values[23])
        #expect(selection.candidate(number: 7) == nil)
    }

    @Test func navigationClampsAndEveryCandidateRemainsReachable() {
        var selection = CandidateSelection()
        let values = candidates(37)
        selection.update(values)
        var visited: [String] = []
        for _ in values.indices {
            if let selected = selection.selected { visited.append(selected.id) }
            selection.move(by: 1)
        }
        #expect(visited == values.map(\.id))
        selection.movePage(by: 1)
        #expect(selection.selected == values.last)
        selection.move(by: -100)
        #expect(selection.selected == values.first)
        #expect(selection.candidate(number: 0) == nil)
        #expect(selection.candidate(number: 10) == nil)
    }

    @Test func editsAndCancellationDiscardOldSelection() {
        var selection = CandidateSelection()
        selection.update(candidates(30))
        selection.movePage(by: 2)
        let replacement = [InputCandidate(text: "你好", language: .simplifiedChinese, score: 100)]
        selection.update(replacement)
        #expect(selection.page == 0)
        #expect(selection.selected == replacement.first)
        #expect(selection.candidate(number: 2) == nil)
        selection.update([])
        selection.move(by: -1)
        selection.movePage(by: 1)
        #expect(selection.selected == nil)
        #expect(selection.visibleRange.isEmpty)
        #expect(selection.pageCount == 0)
        #expect(selection.candidate(number: 1) == nil)
    }

    @Test func selectedNumberCommitsCandidateTextWithoutDecoration() throws {
        var session = InputSession()
        session.append("shi")
        var selection = CandidateSelection()
        selection.update(session.candidates)
        let expected = try #require(selection.candidate(number: 2))
        let commit = session.commitResult(expected, reason: .explicitSelection)
        #expect(commit.text == expected.text)
        #expect(commit.input == "shi")
        #expect(commit.candidate?.id == expected.id)
        #expect(session.buffer.isEmpty)
        var learning = LearningProfile()
        let recorded = learning.record(commit)
        #expect(recorded)
        #expect(learning.entries.count == 1)
    }

    @Test func numberedPrefixLeavesItsExactRemainderEditable() throws {
        var session = InputSession()
        session.append("nihaopengyou")
        let index = try #require(session.candidates.firstIndex { $0.text == "你好" && $0.isPartial })
        var selection = CandidateSelection()
        selection.update(session.candidates)
        selection.move(by: index)
        let candidate = try #require(selection.candidate(number: index % CandidateSelection.pageSize + 1))
        let commit = session.commitResult(candidate, reason: .explicitSelection)
        #expect(commit.text == "你好")
        #expect(commit.input == "nihao")
        #expect(session.buffer == "pengyou")
        #expect(session.candidates.contains { $0.text == "朋友" })
    }

    @Test func languageIdentityAndLiteralFallbackSurvivePaging() throws {
        let english = InputCandidate(text: "he", language: .english, score: 110)
        let chinese = InputCandidate(text: "he", language: .simplifiedChinese, score: 100)
        let literal = InputCandidate(text: "he", language: nil, score: 0)
        var selection = CandidateSelection()
        selection.update([english, chinese] + candidates(19) + [literal])
        #expect(selection.candidate(number: 1)?.id == english.id)
        #expect(selection.candidate(number: 2)?.id == chinese.id)
        selection.move(by: 21)
        #expect(selection.selected == literal)
        #expect(selection.candidate(number: 4)?.isLiteral == true)
    }
}
