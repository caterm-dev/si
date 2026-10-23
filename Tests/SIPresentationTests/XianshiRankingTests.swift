import Testing
import SICore
@testable import SIPresentation

struct XianshiRankingTests {
    @Test func homophonesStayOnTheFirstPageAndCommitExactly() throws {
        for languages: Set<InputLanguage> in [[.simplifiedChinese], Set(InputLanguage.allCases)] {
            for input in ["xianshi", "xian'shi"] {
                for preview in [true, false] {
                    for expanded in [false, true] {
                        var session = InputSession(candidateGeneration: .deferred)
                        session.configure(languages: languages)
                        session.append(input)
                        let request = try #require(session.pendingCandidateRequest)
                        let accepted = session.accept(preview ? request.generatePreview() : request.generate())
                        #expect(accepted)
                        let engineCandidates = session.candidates
                        let display = try #require(engineCandidates.first { $0.text == "显示" && !$0.isPartial })
                        let reality = try #require(engineCandidates.first { $0.text == "现实" && !$0.isPartial })
                        #expect(engineCandidates.first?.lexicalTokenCount == 1)
                        var selection = CandidateSelection()
                        selection.update(engineCandidates)
                        selection.setExpanded(expanded)
                        let firstPage = selection.visibleRange.map { selection.candidates[$0] }
                        #expect(firstPage.contains { $0.id == display.id })
                        #expect(firstPage.contains { $0.id == reality.id })
                        #expect(selection.candidates.prefix(5).map(\.id) == engineCandidates.prefix(5).map(\.id))
                        #expect(selection.candidates.contains { $0.isLiteral && $0.text == input })
                        #expect(selection.candidates.contains { $0.isLexicalPrefix && $0.text == "先" })
                        #expect(selection.candidates.count <= CandidateSelection.maximumCandidates)
                        #expect(session.candidates == engineCandidates)
                        let number = try #require(firstPage.firstIndex { $0.id == display.id }) + 1
                        let chosen = try #require(selection.candidate(number: number))
                        let commit = session.commitResult(chosen, reason: .explicitSelection)
                        #expect(commit.text == "显示" && commit.input == input)
                        #expect(session.buffer.isEmpty)
                    }
                }
            }
        }
    }

    @Test func highScoringPrefixesHaveNoReservedWholeWordPositions() {
        let words = (0..<6).map {
            InputCandidate(text: "Whole \($0)", language: .english, score: 10 - $0, lexicalTokenCount: 1)
        }
        let prefix = InputCandidate(text: "Prefix", language: .english, score: 100,
                                    consumedInputCount: 2, lexicalTokenCount: 1)
        let literal = InputCandidate(text: "Synthetic", language: nil, score: 0)
        var selection = CandidateSelection()
        selection.update([prefix] + words + [literal])
        #expect(selection.candidates == [prefix] + words + [literal])
    }

    @Test func historyKeepsItsPositionAndPrefixesSurviveTheShortlist() {
        let words = (0..<40).map {
            InputCandidate(text: "Whole \($0)", language: .english, score: 50 - $0, lexicalTokenCount: 1)
        }
        let history = InputCandidate(text: "History", language: .english, score: 0,
                                     isHistory: true, historyInput: "Synthetic history")
        let prefix = InputCandidate(text: "Prefix", language: .english, score: 100,
                                    consumedInputCount: 2, lexicalTokenCount: 1)
        let literal = InputCandidate(text: "Synthetic", language: nil, score: 0)
        var selection = CandidateSelection()
        selection.update([prefix] + Array(words.prefix(2)) + [history] + Array(words.dropFirst(2)) + [literal])
        #expect(selection.candidate(number: 4)?.id == history.id)
        #expect(selection.candidates.contains { $0.id == prefix.id })
        #expect(selection.candidates.contains { $0.id == literal.id })
        #expect(selection.candidates.count == CandidateSelection.maximumCandidates)
    }
}
