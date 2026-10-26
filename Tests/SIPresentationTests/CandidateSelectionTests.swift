import Foundation
import Testing
import SICore
@testable import SIPresentation

struct CandidateSelectionTests {
    @Test func expandedGridIsOnePageWithAnIndependentNumberedRow() {
        var selection = CandidateSelection()
        selection.update(candidates(27))
        selection.setExpanded(true)
        for row in 0..<4 {
            if row > 0 { selection.navigate(.row(1)) }
            #expect(selection.row == row && selection.page == 0 && selection.pageCount == 2)
            #expect(selection.displayedRange == 0..<24)
            #expect(selection.candidate(number: 1) == selection.candidates[row * 6])
            #expect(selection.candidate(number: 6) == selection.candidates[row * 6 + 5])
        }
        selection.movePage(by: 1)
        #expect(selection.page == 1 && selection.row == 0)
        #expect(selection.displayedRange == 24..<27 && selection.visibleRange == 24..<27)
        #expect(selection.candidate(number: 3) == selection.candidates.last)
        #expect(selection.candidate(number: 4) == nil)
        for digit in ["7", "8", "9"] { #expect(CandidateSelection.action(keyCode: 0, characters: digit) == nil) }
        selection.setExpanded(false)
        #expect(selection.displayedRange == selection.visibleRange && selection.page == 4)
    }

    @Test func downArrowExpandsWithoutAdvancingTheSelectedCandidate() {
        var selection = CandidateSelection()
        selection.update(candidates(22))
        selection.move(by: 7)
        let chosen = selection.selected
        #expect(CandidateSelection.action(keyCode: 125, characters: nil) == .expand)
        selection.setExpanded(true)
        #expect(selection.selected == chosen && selection.candidate(number: 2) == chosen)
        #expect(CandidateSelection.action(keyCode: 125, characters: nil, isExpanded: true) == .navigate(.row(1)))
        selection.update([])
        #expect(!selection.isExpanded)
    }

    @Test func lingKeepsHigherScoringHomophonesAheadOfItsProtectedMixedAlternative() throws {
        let values = CandidateEngine().candidates(for: "ling", languages: Set(InputLanguage.allCases))
        var selection = CandidateSelection()
        selection.update(values)
        let zero = try #require(selection.candidates.firstIndex { $0.text == "零" })
        let split = try #require(selection.candidates.firstIndex { $0.text == "里NG" && $0.isMixed })
        #expect(zero < split)
        #expect(selection.candidates.count >= values.filter { $0.language == .simplifiedChinese && $0.text.count == 1 }.count)
        #expect(selection.candidates.contains { $0.language == .english })
        #expect(selection.candidates.contains { $0.isLiteral && $0.text == "ling" })
        selection.setExpanded(true)
        selection.move(by: zero)
        let number = selection.selectedIndex % selection.visiblePageSize + 1
        #expect(selection.candidate(number: number)?.text == "零")
        var session = InputSession()
        session.append("ling")
        let result = session.commitResult(try #require(selection.selected), reason: .explicitSelection)
        #expect(result.text == "零" && session.buffer.isEmpty)
    }

    @Test func compactPagesExpandWithoutChangingTheChosenCandidateOrLosingResults() throws {
        var selection = CandidateSelection()
        let values = candidates(22)
        selection.update(values)
        #expect(!selection.isExpanded && selection.visiblePageSize == 6)
        #expect(selection.visibleRange == 0..<6 && selection.pageCount == 4)
        #expect(selection.candidate(number: 6) == values[5])
        #expect(selection.candidate(number: 7) == nil)
        #expect(CandidateSelection.action(keyCode: 121, characters: nil, pageSize: selection.visiblePageSize) == .navigate(.page(1)))
        #expect(CandidateSelection.action(keyCode: 116, characters: nil, pageSize: selection.visiblePageSize) == .navigate(.page(-1)))
        selection.movePage(by: 1)
        selection.move(by: 2)
        let chosen = try #require(selection.selected)
        #expect(chosen == values[8])
        selection.setExpanded(true)
        #expect(selection.visibleRange == 6..<12 && selection.displayedRange == 0..<22 && selection.selected == chosen)
        #expect(selection.candidate(number: 3) == chosen)
        selection.setExpanded(false)
        #expect(selection.visibleRange == 6..<12 && selection.selected == chosen)
        #expect(selection.candidate(number: 3) == chosen)
        selection.move(by: -100)
        var visited: [String] = []
        for _ in values.indices {
            visited.append(try #require(selection.selected).id)
            selection.move(by: 1)
        }
        #expect(visited == values.map(\.id))
        #expect(selection.page == 3 && selection.visibleRange == 18..<22)
        #expect(selection.candidate(number: 4) == values.last)
        #expect(selection.candidate(number: 5) == nil)
        selection.setExpanded(true)
        selection.update([])
        #expect(!selection.isExpanded)
    }

    @Test func rankedPrefixesAndWholeChoicesKeepTheirEngineOrder() throws {
        let whole = candidates(14)
        let literal = InputCandidate(text: "synthetic", language: nil, score: 0)
        let longPrefix = InputCandidate(text: "很长的组合", language: .simplifiedChinese, score: 62, consumedInputCount: 18)
        let word = InputCandidate(text: "词语", language: .simplifiedChinese, score: 74, consumedInputCount: 6, lexicalTokenCount: 1)
        let letter = InputCandidate(text: "字", language: .simplifiedChinese, score: 74, consumedInputCount: 2, lexicalTokenCount: 1)
        let values = [word, letter, longPrefix] + whole + [literal]
        var selection = CandidateSelection()
        selection.update(values)
        #expect(Array(selection.candidates.prefix(5)) == [word, letter, longPrefix] + Array(whole.prefix(2)))
        #expect(selection.candidate(number: 1) == word)
        #expect(selection.candidates.count == values.count)
        #expect(Set(selection.candidates.map(\.id)) == Set(values.map(\.id)))
        #expect(selection.candidates.last == literal)
        selection.setExpanded(true)
        #expect(Array(selection.candidates.prefix(5)) == [word, letter, longPrefix] + Array(whole.prefix(2)))
        selection.update(values)
        #expect(Array(selection.candidates.prefix(5)) == [word, letter, longPrefix] + Array(whole.prefix(2)))
    }

    @Test func rankedPrefixesUseOnlyConsumedSpellingForLearningAndRemainCommittable() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        var session = InputSession()
        let learning = LearningProfile(entries: [
            LearnedPreference(input: "nihao", text: "你好", language: .simplifiedChinese, strength: 8, lastUsed: now),
        ], now: now)
        session.configure(languages: [.simplifiedChinese], learning: learning, now: now)
        session.append("nihaopengyou")
        let greeting = try #require(session.candidates.first { $0.text == "你好" && $0.isPartial })
        #expect(session.presentationScore(for: greeting, now: now) > greeting.inputScore)
        let baseCandidates = session.candidates
        var selection = CandidateSelection()
        selection.update(session.candidates)
        #expect(session.candidates == baseCandidates)
        let index = try #require(selection.candidates.firstIndex { $0.id == greeting.id })
        selection.move(by: index)
        let number = index % selection.visiblePageSize + 1
        let commit = session.commitResult(selection.candidate(number: number), reason: .explicitSelection, now: now)
        #expect(commit.text == "你好" && commit.input == "nihao")
        #expect(session.buffer == "pengyou")
        session.configure(languages: [.simplifiedChinese], now: now)
        let friend = try #require(session.candidates.first { $0.text == "朋友" && !$0.isPartial })
        #expect(session.presentationScore(for: friend, now: now) == friend.rankingScore)
    }

    private func candidates(_ count: Int) -> [InputCandidate] {
        (0..<count).map { InputCandidate(text: "word\($0)", language: .english, score: count - $0, lexicalTokenCount: 1) }
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
        selection.move(by: 6)
        #expect(selection.page == 0)
        #expect(selection.visibleRange == 6..<12)
        #expect(selection.candidate(number: 2) == values[7])
        selection.movePage(by: 1)
        #expect(selection.selected == values[6])
        #expect(selection.candidate(number: 6) == values[11])
        #expect(selection.candidate(number: 7) == nil)
    }

    @Test func navigationClampsAndEveryShortlistedCandidateRemainsReachable() {
        var selection = CandidateSelection()
        selection.setExpanded(true)
        let values = candidates(27)
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

    @Test func arrowsNavigateColumnsAndRowsWithoutTurningTheGridPage() {
        var selection = CandidateSelection()
        selection.update(candidates(27))
        #expect(CandidateSelection.action(keyCode: 123, characters: nil) == .navigate(.column(-1)))
        #expect(CandidateSelection.action(keyCode: 124, characters: nil) == .navigate(.column(1)))
        #expect(CandidateSelection.action(keyCode: 123, characters: nil, isExpanded: true) == .navigate(.column(-1)))
        #expect(CandidateSelection.action(keyCode: 124, characters: nil, isExpanded: true) == .navigate(.column(1)))
        #expect(CandidateSelection.action(keyCode: 126, characters: nil, isExpanded: true) == .navigate(.row(-1)))
        selection.navigate(.column(1))
        #expect(selection.selectedIndex == 1)
        selection.move(by: 4)
        selection.navigate(.column(1))
        #expect(selection.selectedIndex == 6 && selection.page == 1)
        selection.setExpanded(true)
        selection.navigate(.row(1))
        #expect(selection.selectedIndex == 12 && selection.page == 0)
        selection.navigate(.column(1))
        #expect(selection.selectedIndex == 13)
        selection.navigate(.row(-1))
        #expect(selection.selectedIndex == 7)
        selection.navigate(.column(-10))
        #expect(selection.selectedIndex == 6)
        selection.navigate(.column(10))
        #expect(selection.selectedIndex == 11)
        selection.navigate(.row(10))
        #expect(selection.selectedIndex == 23 && selection.page == 0)
        selection.navigate(.row(1))
        #expect(selection.selectedIndex == 23)
        selection.navigate(.page(1))
        #expect(selection.selectedIndex == 26 && selection.page == 1)
        selection.navigate(.row(1))
        selection.navigate(.column(1))
        #expect(selection.selectedIndex == 26)
        selection.navigate(.page(-1))
        #expect(selection.selectedIndex == 2 && selection.page == 0)
    }

    @Test(arguments: [false, true])
    func largeResultSetsKeepRankedOrderLanguageIdentitiesAndExactLiteral(expanded: Bool) throws {
        let whole = candidates(900)
        let chinese = InputCandidate(text: "word0", language: .simplifiedChinese, score: 0)
        let mixed = InputCandidate(text: "你好world", language: .simplifiedChinese, score: 0, isMixed: true)
        let literal = InputCandidate(text: "SyntheticID", language: nil, score: 0)
        let prefixes = (0..<12).map {
            InputCandidate(text: "前缀\($0)", language: .simplifiedChinese, score: $0, consumedInputCount: $0 + 1)
        }
        let values = whole + [chinese, mixed] + prefixes + [literal]
        var selection = CandidateSelection()
        selection.setExpanded(expanded)
        selection.update(values)
        let shortlist = selection.candidates
        #expect(shortlist.count == 27)
        #expect(selection.pageCount == (expanded ? 2 : 5))
        #expect(Array(shortlist.prefix(9)) == Array(whole.prefix(9)))
        #expect(shortlist.contains(whole[0]) && shortlist.contains(chinese) && shortlist.contains(mixed))
        #expect(shortlist.last == literal)
        #expect(Set(shortlist.map(\.id)).count == shortlist.count)
        // Same text in two languages remains distinguishable; paging and digits use the shortlist.
        for (index, candidate) in shortlist.enumerated() {
            #expect(selection.selected == candidate)
            #expect(selection.candidate(number: index % selection.visiblePageSize + 1) == candidate)
            selection.move(by: 1)
        }
        #expect(selection.selected == literal)
        selection.update(values)
        #expect(selection.candidates == shortlist && selection.selectedIndex == 0)
        #expect(values.count == 915)
    }

    @Test(arguments: [26, 27, 28, 900])
    func shortlistKeepsRankedChoicesAndLiteralAcrossTheLimit(count: Int) {
        let ranked = candidates(count - 1)
        let literal = InputCandidate(text: "UnchangedID", language: nil, score: 0)
        var selection = CandidateSelection()
        selection.update(ranked + [literal])
        #expect(selection.candidates == Array(ranked.prefix(min(count, 27) - 1)) + [literal])
        selection.update([literal])
        #expect(selection.candidates == [literal])
        selection.update([])
        #expect(selection.candidates.isEmpty)
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
