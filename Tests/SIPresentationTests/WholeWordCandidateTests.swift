import Testing
import SICore
@testable import SIPresentation

struct WholeWordCandidateTests {
    @Test func fullSpellingWordSurvivesBothSearchStagesAndThePanelShortlist() throws {
        for languages: Set<InputLanguage> in [[.simplifiedChinese], Set(InputLanguage.allCases)] {
            for input in ["danci", "dan'ci"] {
                var session = InputSession(candidateGeneration: .deferred)
                session.configure(languages: languages)
                for letter in input { session.append(String(letter)) }
                let request = try #require(session.pendingCandidateRequest)
                for result in [request.generatePreview(), request.generate()] {
                    #expect(session.accept(result) == true)
                    var selection = CandidateSelection()
                    selection.update(session.candidates)
                    for expanded in [false, true] {
                        selection.setExpanded(expanded)
                        let index = try #require(selection.candidates.firstIndex { $0.text == "单词" && !$0.isPartial })
                        selection.move(by: index - selection.selectedIndex)
                        let number = index % selection.visiblePageSize + 1
                        let word = try #require(selection.candidate(number: number))
                        #expect(word.text == "单词" && !word.isPartial && !word.hasCompletion)
                        #expect(word.language == .simplifiedChinese && !word.isMixed)
                        #expect(selection.candidates.last?.text == input && selection.candidates.last?.isLiteral == true)
                    }
                }
                let chosen = try #require(session.candidates.first { $0.text == "单词" && !$0.isPartial })
                let commit = session.commitResult(chosen, reason: .explicitSelection)
                #expect(commit.text == "单词" && commit.input == input && session.buffer.isEmpty)
            }
        }
    }
}
