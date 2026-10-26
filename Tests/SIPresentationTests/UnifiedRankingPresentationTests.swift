import Testing
import SICore
@testable import SIPresentation

struct UnifiedRankingPresentationTests {
    @Test func maExactReadingLeadsAndCommitsInBothLayoutsAndSearchStages() throws {
        for preview in [true, false] {
            for expanded in [false, true] {
                var session = InputSession(candidateGeneration: .deferred)
                session.configure(languages: Set(InputLanguage.allCases))
                session.append("ma")
                let request = try #require(session.pendingCandidateRequest)
                let accepted = session.accept(preview ? request.generatePreview() : request.generate())
                #expect(accepted)
                var selection = CandidateSelection()
                selection.update(session.candidates)
                selection.setExpanded(expanded)
                let candidate = try #require(selection.candidate(number: 1))
                #expect(candidate.text == "吗" && candidate.language == .simplifiedChinese)
                #expect(selection.candidates.contains { $0.text == "may" && $0.language == .english })
                #expect(selection.candidates.last?.text == "ma" && selection.candidates.last?.isLiteral == true)
                let commit = session.commitResult(candidate, reason: .explicitSelection)
                #expect(commit.text == "吗" && commit.input == "ma")
                #expect(session.buffer.isEmpty)
            }
        }
    }

    @Test func fullSpellingSelectionsCommitExactlyInBothLayouts() throws {
        for languages: Set<InputLanguage> in [[.simplifiedChinese], Set(InputLanguage.allCases)] {
            for input in ["danci", "dan'ci"] {
                var session = InputSession(candidateGeneration: .deferred)
                session.configure(languages: languages)
                session.append(input)
                let request = try #require(session.pendingCandidateRequest)
                var selection = CandidateSelection()
                for result in [request.generatePreview(), request.generate()] {
                    let accepted = session.accept(result)
                    #expect(accepted)
                    selection.update(session.candidates)
                    for expanded in [false, true] {
                        selection.setExpanded(expanded)
                        let index = try #require(selection.candidates.firstIndex { $0.text == "单词" && !$0.isPartial })
                        selection.move(by: index - selection.selectedIndex)
                        #expect(selection.selected?.text == "单词")
                        #expect(selection.candidate(number: index % selection.visiblePageSize + 1)?.text == "单词")
                        #expect(selection.candidates.contains { $0.isLiteral && $0.text == input })
                    }
                }
                let selected = try #require(selection.selected)
                let commit = session.commitResult(selected, reason: .explicitSelection)
                #expect(commit.text == "单词" && commit.input == input)
                #expect(session.buffer.isEmpty)
            }
        }
    }

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
        let prefix = InputCandidate(text: "a", language: .english, score: 100, consumedInputCount: 1, lexicalTokenCount: 1)
        let chinese = (0..<40).map { InputCandidate(text: "测试\($0)", language: .simplifiedChinese, score: 99 - $0, lexicalTokenCount: 1) }
        let english = InputCandidate(text: "ability", language: .english, score: -10, hasCompletion: true, lexicalTokenCount: 1)
        let literal = InputCandidate(text: "abilit", language: nil, score: 0)
        var selection = CandidateSelection()
        selection.update([prefix] + chinese + [english, literal])
        #expect(selection.candidates.count == CandidateSelection.maximumCandidates)
        #expect(selection.candidates.contains { $0.id == english.id })
        #expect(selection.candidates.contains { $0.id == literal.id })
        #expect(selection.candidates.contains { $0.id == chinese[0].id })
    }
}
