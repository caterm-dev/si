import Foundation
import Testing
import SICore
@testable import SIPresentation

struct CandidateSelectionTests {
    @Test func compactPagesExpandWithoutChangingTheChosenCandidateOrLosingResults() throws {
        var selection = CandidateSelection()
        let values = candidates(22)
        selection.update(values)
        #expect(!selection.isExpanded && selection.visiblePageSize == 5)
        #expect(selection.visibleRange == 0..<5)
        #expect(selection.candidate(number: 5) == values[4])
        #expect(selection.candidate(number: 6) == nil)
        #expect(CandidateSelection.action(keyCode: 121, characters: nil, pageSize: selection.visiblePageSize) == .move(5))
        #expect(CandidateSelection.action(keyCode: 116, characters: nil, pageSize: selection.visiblePageSize) == .move(-5))
        selection.movePage(by: 1)
        selection.move(by: 2)
        let chosen = try #require(selection.selected)
        #expect(chosen == values[7])
        selection.setExpanded(true)
        #expect(selection.visibleRange == 0..<9 && selection.selected == chosen)
        #expect(selection.candidate(number: 8) == chosen)
        selection.setExpanded(false)
        #expect(selection.visibleRange == 5..<10 && selection.selected == chosen)
        #expect(selection.candidate(number: 3) == chosen)
        selection.move(by: -100)
        var visited: [String] = []
        for _ in values.indices {
            visited.append(try #require(selection.selected).id)
            selection.move(by: 1)
        }
        #expect(visited == values.map(\.id))
        #expect(selection.page == 4 && selection.visibleRange == 20..<22)
        #expect(selection.candidate(number: 2) == values.last)
        #expect(selection.candidate(number: 3) == nil)
        selection.setExpanded(true)
        selection.update([])
        #expect(!selection.isExpanded)
    }

    @Test func twoWholeChoicesThenHighScoringPrefixesKeepAllOtherAlternatives() throws {
        let whole = candidates(14)
        let literal = InputCandidate(text: "synthetic", language: nil, score: 0)
        let longPrefix = InputCandidate(text: "很长的组合", language: .simplifiedChinese, score: 62, consumedInputCount: 18)
        let word = InputCandidate(text: "词语", language: .simplifiedChinese, score: 74, consumedInputCount: 6)
        let letter = InputCandidate(text: "字", language: .simplifiedChinese, score: 74, consumedInputCount: 2)
        let values = whole + [longPrefix, word, letter, literal]
        var selection = CandidateSelection()
        selection.update(values)
        #expect(Array(selection.candidates.prefix(5)) == Array(whole.prefix(2)) + [word, letter, longPrefix])
        #expect(selection.candidate(number: 3) == word)
        #expect(selection.candidates.count == values.count)
        #expect(Set(selection.candidates.map(\.id)) == Set(values.map(\.id)))
        #expect(selection.candidates.last == literal)
        selection.setExpanded(true)
        #expect(Array(selection.candidates.prefix(5)) == Array(whole.prefix(2)) + [word, letter, longPrefix])
        selection.update(values)
        #expect(Array(selection.candidates.prefix(5)) == Array(whole.prefix(2)) + [word, letter, longPrefix])
    }

    @Test func featuredPrefixesUseOnlyConsumedSpellingForLearningAndRemainCommittable() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        var session = InputSession()
        let learning = LearningProfile(entries: [
            LearnedPreference(input: "nihao", text: "你好", language: .simplifiedChinese, strength: 8, lastUsed: now),
        ], now: now)
        session.configure(languages: [.simplifiedChinese], learning: learning, now: now)
        session.append("nihaopengyou")
        let greeting = try #require(session.candidates.first { $0.text == "你好" && $0.isPartial })
        #expect(session.presentationScore(for: greeting, now: now) > greeting.rankingScore)
        let baseCandidates = session.candidates
        var selection = CandidateSelection()
        selection.update(session.candidates, prefixScore: { session.presentationScore(for: $0, now: now) })
        #expect(session.candidates == baseCandidates)
        #expect(selection.candidate(number: 3)?.id == greeting.id)
        let commit = session.commitResult(selection.candidate(number: 3), reason: .explicitSelection, now: now)
        #expect(commit.text == "你好" && commit.input == "nihao")
        #expect(session.buffer == "pengyou")
        session.configure(languages: [.simplifiedChinese], now: now)
        let friend = try #require(session.candidates.first { $0.text == "朋友" && !$0.isPartial })
        #expect(session.presentationScore(for: friend, now: now) == friend.rankingScore)
    }

    private func candidates(_ count: Int) -> [InputCandidate] {
        (0..<count).map { InputCandidate(text: "word\($0)", language: .english, score: count - $0) }
    }

    @Test func arrowsAndDigitsReferToTheSamePage() throws {
        var selection = CandidateSelection()
        selection.setExpanded(true)
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
        selection.setExpanded(true)
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
        selection.setExpanded(true)
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
        selection.setExpanded(true)
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
        var selection = CandidateSelection()
        selection.setExpanded(true)
        selection.update(session.candidates)
        let index = try #require(selection.candidates.firstIndex { $0.text == "你好" && $0.isPartial })
        selection.move(by: index)
        let candidate = try #require(selection.candidate(number: index % CandidateSelection.pageSize + 1))
        let commit = session.commitResult(candidate, reason: .explicitSelection)
        #expect(commit.text == "你好")
        #expect(commit.input == "nihao")
        #expect(session.buffer == "pengyou")
        #expect(session.candidates.contains { $0.text == "朋友" })
    }

    @Test(arguments: [false, true])
    func languageIdentityAndLiteralFallbackSurvivePaging(expanded: Bool) throws {
        let english = InputCandidate(text: "he", language: .english, score: 110)
        let chinese = InputCandidate(text: "he", language: .simplifiedChinese, score: 100)
        let literal = InputCandidate(text: "he", language: nil, score: 0)
        var selection = CandidateSelection()
        selection.setExpanded(expanded)
        selection.update([english, chinese] + candidates(19) + [literal])
        #expect(selection.candidate(number: 1)?.id == english.id)
        #expect(selection.candidate(number: 2)?.id == chinese.id)
        selection.move(by: 21)
        #expect(selection.selected == literal)
        #expect(selection.candidate(number: selection.selectedIndex % selection.visiblePageSize + 1)?.isLiteral == true)
    }
}
