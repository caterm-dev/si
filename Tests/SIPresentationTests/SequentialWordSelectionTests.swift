import AppKit
import Testing
@testable import SICore
@testable import SIPresentation

struct SequentialWordSelectionTests {
    @Test func reportedTitleKeepsItsFirstCharacterSelectableWithExactRemainder() throws {
        for (input, consumed) in [("sheguofennudehai", "she"), ("she'guo'fen'nu'de'hai", "she'")] {
            for languages: Set<InputLanguage> in [[.simplifiedChinese], Set(InputLanguage.allCases)] {
                for preview in [true, false] {
                    for expanded in [false, true] {
                        var session = InputSession(candidateGeneration: .deferred)
                        session.configure(languages: languages)
                        session.append(input)
                        let request = try #require(session.pendingCandidateRequest)
                        #expect(session.accept(preview ? request.generatePreview() : request.generate()) == true)
                        var selection = CandidateSelection()
                        selection.update(session.candidates)
                        selection.setExpanded(expanded)
                        let ordinary = selection.candidates.filter { !$0.isLiteral && !$0.isHistory }
                        #expect(ordinary.prefix(4).allSatisfy { $0.lexicalTokenCount != 1 })
                        #expect(ordinary.dropFirst(4).allSatisfy { $0.lexicalTokenCount == 1 })
                        let index = try #require(selection.candidates.firstIndex { $0.text == "涉" && $0.isLexicalPrefix })
                        selection.move(by: index)
                        let word = try #require(selection.candidate(number: index % selection.visiblePageSize + 1))
                        #expect(word.text == "涉" && word.consumedInputCount == consumed.count)
                        #expect(selection.candidates.last?.text == input && selection.candidates.last?.isLiteral == true)
                        let commit = session.commitResult(word, reason: .explicitSelection)
                        #expect(commit.text == "涉" && commit.input == consumed)
                        let remainder = String(input.dropFirst(consumed.count))
                        #expect(commit.remainingInput == remainder && session.buffer == remainder)
                    }
                }
            }
        }
    }

    @MainActor
    @Test func reportedTitleCanBeChosenWordByWordFromTheRenderedPages() throws {
        var session = InputSession()
        session.configure(languages: Set(InputLanguage.allCases))
        session.append("sheguofennudehai")
        var output = ""
        for text in ["涉", "过", "愤怒", "的", "海"] {
            var selection = CandidateSelection()
            selection.update(session.candidates)
            let index = try #require(selection.candidates.firstIndex {
                $0.text == text && ($0.isLexicalPrefix || !$0.isPartial)
            })
            for expanded in [false, true] {
                selection.setExpanded(expanded)
                selection.move(by: index - selection.selectedIndex)
                let number = index % selection.visiblePageSize + 1
                let word = try #require(selection.candidate(number: number))
                #expect(word.text == text)
                let view = CandidateListView()
                var clicked: String?
                view.onSelect = { clicked = $0 }
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    view.appearance = NSAppearance(named: appearance)
                    view.render(selection)
                    view.frame = NSRect(origin: .zero, size: view.preferredSize)
                    view.layoutSubtreeIfNeeded()
                    let row = try #require(view.rows.first { $0.candidateID == word.id })
                    #expect(row.candidateID == word.id && !row.candidateLabel.isHidden)
                    row.performClick(nil)
                    #expect(clicked == word.id)
                    #expect(row.accessibilityLabel()?.contains(text) == true)
                    if text == "涉", let path = ProcessInfo.processInfo.environment["SI_TITLE_PREFIX_SNAPSHOT_PATH"] {
                        var firstPage = selection
                        firstPage.move(by: -firstPage.selectedIndex)
                        view.render(firstPage)
                        view.frame = NSRect(origin: .zero, size: view.preferredSize)
                        view.layoutSubtreeIfNeeded()
                        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                        view.effectiveAppearance.performAsCurrentDrawingAppearance {
                            view.cacheDisplay(in: view.bounds, to: bitmap)
                        }
                        let layout = expanded ? "expanded" : "compact"
                        let style = appearance == .aqua ? "light" : "dark"
                        try #require(bitmap.representation(using: .png, properties: [:]))
                            .write(to: URL(filePath: "\(path).\(layout).\(style).png"))
                    }
                }
            }
            output += session.commitResult(selection.selected, reason: .explicitSelection).text
        }
        #expect(output == "涉过愤怒的海" && session.buffer.isEmpty)
    }

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
                #expect(view.rows.map(\.candidateID) == selection.displayedRange.map { selection.candidates[$0].id })
                #expect(view.rows.allSatisfy { !$0.candidateLabel.isHidden })
                let activeRow = selection.visibleRange.lowerBound - selection.displayedRange.lowerBound
                view.rows[activeRow].performClick(nil)
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

    @Test func sentencePagesKeepRankedWordsAndAtMostFourConstructedChoices() throws {
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
                let firstWord = try #require(selection.candidates.first { $0.text == "比如" && $0.isLexicalPrefix })
                #expect(firstWord.consumedInputCount == 4)
                #expect(selection.candidates.count <= CandidateSelection.maximumCandidates)
                #expect(session.candidates == engineCandidates)
                #expect(selection.candidates.last?.text == "biruzhege" && selection.candidates.last?.isLiteral == true)
                let indices = try selection.candidates.filter { $0.lexicalTokenCount == 1 }.map { candidate in
                    try #require(engineCandidates.firstIndex { $0.id == candidate.id })
                }
                #expect(indices == indices.sorted())
                #expect(selection.candidates.filter { !$0.isLiteral && !$0.isHistory && $0.lexicalTokenCount != 1 }.count <= 4)
                for (left, right) in zip(engineCandidates.dropLast(), engineCandidates.dropLast().dropFirst()) {
                    #expect(left.inputScore >= right.inputScore)
                }
                for expanded in [false, true] {
                    selection.setExpanded(expanded)
                    selection.move(by: -selection.selectedIndex)
                    while true {
                        for (number, index) in selection.visibleRange.enumerated() {
                            #expect(selection.candidate(number: number + 1)?.id == selection.candidates[index].id)
                        }
                        if selection.page == selection.pageCount - 1 { break }
                        selection.movePage(by: 1)
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
            let index = try #require(selection.candidates.firstIndex { $0.text == "比如" && $0.isLexicalPrefix })
            selection.move(by: index)
            let word = try #require(selection.candidate(number: index % selection.visiblePageSize + 1))
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

    @Test func shortlistKeepsRankedCharactersAndWordsWithoutTypePromotion() {
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
        let values = characters + [sentence, second] + words + [english, mixed, literal]
        var selection = CandidateSelection()
        selection.update(values)
        #expect(Array(selection.candidates.prefix(4)) == Array(characters.prefix(4)))
        #expect(selection.candidates.contains(english) && selection.candidates.contains(mixed))
        #expect(selection.candidates.last == literal && selection.candidates.count == 27)
        let expected = selection.candidates
        selection.update(values)
        #expect(selection.candidates == expected)
    }
}
