import AppKit
import Testing
import SICore
@testable import SIPresentation

struct SequentialWordSelectionTests {
    @MainActor
    @Test func sentencePagesRenderTheirActualWordChoicesInBothAppearances() throws {
        var session = InputSession()
        session.append("biruzhege")
        var selection = CandidateSelection()
        selection.setExpanded(true)
        selection.update(session.candidates)
        let view = CandidateListView()
        var clicked: String?
        view.onSelect = { clicked = $0 }
        for page in 0...1 {
            if page > 0 { selection.movePage(by: 1) }
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                view.appearance = try #require(NSAppearance(named: appearance))
                view.render(selection)
                view.frame = NSRect(origin: .zero, size: view.preferredSize)
                view.layoutSubtreeIfNeeded()
                #expect(view.rows.map(\.candidateID) == selection.visibleRange.map { selection.candidates[$0].id })
                #expect(view.rows.allSatisfy { !$0.candidateLabel.isHidden })
                view.rows[0].performClick(nil)
                #expect(clicked == selection.candidate(number: 1)?.id)
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.effectiveAppearance.performAsCurrentDrawingAppearance {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                }
                if let path = ProcessInfo.processInfo.environment["SI_WORD_SELECTION_SNAPSHOT_PATH"] {
                    let suffix = appearance == .aqua ? "light" : "dark"
                    try #require(bitmap.representation(using: .png, properties: [:]))
                        .write(to: URL(filePath: "\(path).page\(page + 1).\(suffix).png"))
                }
            }
        }
    }

    @Test func sentencePagesOfferWordsAndCharactersInsteadOfMoreSentenceExpansions() throws {
        for languages: Set<InputLanguage> in [[.simplifiedChinese], Set(InputLanguage.allCases)] {
            var session = InputSession(candidateGeneration: .deferred)
            session.configure(languages: languages)
            session.append("biruzhege")
            let request = try #require(session.pendingCandidateRequest)
            for result in [request.generatePreview(), request.generate()] {
                #expect(session.accept(result) == true)
                let engineCandidates = session.candidates
                var selection = CandidateSelection()
                selection.update(engineCandidates)
                #expect(selection.candidates.first?.text == "比如这个")
                #expect(selection.candidate(number: 3)?.text == "比如")
                #expect(selection.candidate(number: 3)?.consumedInputCount == 4)
                #expect(selection.candidate(number: 4)?.text == "比")
                #expect(!selection.candidates.contains { $0.text == "比如这" && $0.isPartial })
                #expect(selection.candidates.count <= CandidateSelection.maximumCandidates)
                #expect(session.candidates == engineCandidates)
                #expect(selection.candidates.last?.text == "biruzhege" && selection.candidates.last?.isLiteral == true)
                let whole = selection.candidates.filter { !$0.isPartial && !$0.isLiteral && !$0.isMixed }
                #expect(whole.count == 2)
                for expanded in [false, true] {
                    selection.setExpanded(expanded)
                    selection.move(by: -selection.selectedIndex)
                    selection.movePage(by: 1)
                    #expect(selection.page == 1)
                    let page = selection.visibleRange.map { selection.candidates[$0] }
                    #expect(page.allSatisfy { $0.isLexicalPrefix || $0.isLiteral || $0.isMixed })
                    #expect(page.contains { $0.isLexicalPrefix && $0.text.count == 1 })
                    for (number, index) in selection.visibleRange.enumerated() {
                        #expect(selection.candidate(number: number + 1)?.id == selection.candidates[index].id)
                    }
                }
                for language in languages {
                    if engineCandidates.contains(where: { $0.language == language && !$0.isMixed }) {
                        #expect(selection.candidates.contains { $0.language == language && !$0.isMixed })
                    }
                }
                if engineCandidates.contains(where: \.isMixed) { #expect(selection.candidates.contains { $0.isMixed }) }
            }
        }
    }

    @Test func selectingTheFirstWordConsumesOnlyItsSpellingAndContinuesWithTheNextWord() throws {
        for (input, consumed) in [("biruzhege", "biru"), ("bi'ru'zhege", "bi'ru'")] {
            var session = InputSession()
            session.configure(languages: [.simplifiedChinese])
            session.append(input)
            var selection = CandidateSelection()
            selection.update(session.candidates)
            let word = try #require(selection.candidate(number: 3))
            #expect(word.text == "比如" && word.isLexicalPrefix)
            let commit = session.commitResult(word, reason: .explicitSelection)
            #expect(commit.input == consumed && commit.text == "比如")
            #expect(session.buffer == "zhege" && commit.remainingInput == "zhege")
            selection.update(session.candidates)
            let next = try #require(selection.candidate(number: 1))
            #expect(next.text == "这个")
            #expect(commit.text + session.commit(next) == "比如这个")
            #expect(session.buffer.isEmpty)
        }
    }

    @Test func lexicalWholeWordsAndEnglishCompletionsKeepTheirRankedAlternatives() {
        for input in ["danci", "abilit", "ability"] {
            var session = InputSession()
            session.append(input)
            var selection = CandidateSelection()
            selection.update(session.candidates)
            #expect(selection.candidates.contains { $0.text == (input == "danci" ? "单词" : "ability") && !$0.isPartial })
            #expect(selection.candidates.contains { !$0.isPartial && !$0.isLiteral && $0.hasCompletion })
            #expect(selection.candidates.last?.text == input && selection.candidates.last?.isLiteral == true)
        }
    }

    @Test func wordOrderingUsesConsumedSpellingPreferencesAndReservesOtherLanguageChoices() {
        let sentence = InputCandidate(text: "完整句子", language: .simplifiedChinese, score: 10, lexicalTokenCount: 3)
        let second = InputCandidate(text: "另一整句", language: .simplifiedChinese, score: 9, lexicalTokenCount: 3)
        let words = ["词语", "其他"].enumerated().map {
            InputCandidate(text: $0.element, language: .simplifiedChinese, score: 5 - $0.offset,
                           consumedInputCount: 6, lexicalTokenCount: 1)
        }
        let characters = (0..<30).map {
            InputCandidate(text: String(UnicodeScalar(0x4E00 + $0)!), language: .simplifiedChinese, score: 100 - $0,
                           consumedInputCount: 2, lexicalTokenCount: 1)
        }
        let english = InputCandidate(text: "English candidate", language: .english, score: -100)
        let mixed = InputCandidate(text: "中English", language: .simplifiedChinese, score: -101, isMixed: true)
        let literal = InputCandidate(text: "SyntheticInput", language: nil, score: 0)
        let values = [sentence, second] + words + characters + [english, mixed, literal]
        var selection = CandidateSelection()
        selection.update(values, prefixScore: { $0.text == "其他" ? 200 : $0.rankingScore })
        #expect(Array(selection.candidates.prefix(4)) == [sentence, second, words[1], words[0]])
        #expect(selection.candidates.contains(english) && selection.candidates.contains(mixed))
        #expect(selection.candidates.last == literal && selection.candidates.count == 27)
        let expected = selection.candidates
        selection.update(values, prefixScore: { $0.text == "其他" ? 200 : $0.rankingScore })
        #expect(selection.candidates == expected)
    }
}
