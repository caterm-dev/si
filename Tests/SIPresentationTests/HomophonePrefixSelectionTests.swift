import Testing
import SICore
@testable import SIPresentation

struct HomophonePrefixSelectionTests {
    @Test func commonCharacterRemainsSelectableWithBothLanguagesEnabled() throws {
        for input in ["cichuxiande", "ci'chuxian'de"] {
            for languages: Set<InputLanguage> in [[.simplifiedChinese], Set(InputLanguage.allCases)] {
                for preview in [false, true] {
                    var session = InputSession(candidateGeneration: .deferred)
                    session.configure(languages: languages)
                    session.append(input)
                    let request = try #require(session.pendingCandidateRequest)
                    let accepted = session.accept(preview ? request.generatePreview() : request.generate())
                    #expect(accepted)
                    var selection = CandidateSelection()
                    selection.update(session.candidates)
                    selection.setExpanded(true)
                    let wordIndex = try #require(selection.candidates.firstIndex { $0.text == "词" && $0.isPartial })
                    let uncommonIndex = try #require(selection.candidates.firstIndex { $0.text == "慈" && $0.isPartial })
                    #expect(wordIndex < uncommonIndex)
                    selection.move(by: wordIndex)
                    #expect(selection.page == wordIndex / selection.pageCapacity)
                    let word = try #require(selection.candidate(number: wordIndex % selection.visiblePageSize + 1))
                    #expect(word.text == "词" && word.language == .simplifiedChinese && !word.isMixed)
                    let commit = session.commitResult(word, reason: .explicitSelection)
                    #expect(commit.text == "词")
                    #expect(commit.input == (input.contains("'") ? "ci'" : "ci"))
                    #expect(session.buffer == (input.contains("'") ? "chuxian'de" : "chuxiande"))
                    #expect(session.candidates.last?.text == session.buffer && session.candidates.last?.isLiteral == true)
                    let remainderRequest = try #require(session.pendingCandidateRequest)
                    let remainderAccepted = session.accept(preview ? remainderRequest.generatePreview() : remainderRequest.generate())
                    #expect(remainderAccepted)
                    let remainder = try #require(session.candidates.first { $0.text == "出现的" && !$0.isPartial })
                    let ending = session.commitResult(remainder, reason: .explicitSelection)
                    #expect(commit.text + ending.text == "词出现的" && session.buffer.isEmpty)
                }
            }
        }
    }
}
