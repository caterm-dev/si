import Testing
import SICore
@testable import SIPresentation

struct WholeWordCandidateTests {
    @Test func continuousCompositionsLeadAndDefaultConfirmationCommitsTheWholeInput() throws {
        for (input, expected) in [("iwanttobuild", "I want to build"), ("nihaopengyou", "你好朋友"),
                                   ("biruzhege", "比如这个"), ("danci", "单词"),
                                   ("zhegeshurufakeyishuruzhongwenheyingwen", "这个输入法可以输入中文和英文")] {
            let single: Set<InputLanguage> = input == "iwanttobuild" ? [.english] : [.simplifiedChinese]
            for languages in [single, Set(InputLanguage.allCases)] {
                for preview in [true, false] {
                    for expanded in [true, false] {
                        var session = InputSession(candidateGeneration: .deferred)
                        session.configure(languages: languages)
                        for letter in input { session.append(String(letter)) }
                        let request = try #require(session.pendingCandidateRequest)
                        let accepted = session.accept(preview ? request.generatePreview() : request.generate())
                        #expect(accepted)
                        var selection = CandidateSelection()
                        selection.update(session.candidates)
                        selection.setExpanded(expanded)
                        let chosen = try #require(selection.candidate(number: 1))
                        #expect(chosen.text == expected && !chosen.isPartial)
                        let commit = session.commitResult(chosen, reason: .defaultAcceptance)
                        #expect(commit.text == expected && commit.input == input && commit.remainingInput.isEmpty)
                        #expect(session.buffer.isEmpty)
                    }
                }
            }
        }
    }

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
