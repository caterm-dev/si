import AppKit
import Testing
import SICore
@testable import SIPresentation

struct UnifiedRankingPresentationTests {
    @MainActor
    @Test func longCompositionKeepsOnlyFourHypothesesThenSelectableWordsInBothLayouts() throws {
        for preview in [true, false] {
            for expanded in [false, true] {
                var session = InputSession(candidateGeneration: .deferred)
                session.append("mingtianwomenqubeijing")
                let request = try #require(session.pendingCandidateRequest)
                #expect(session.accept(preview ? request.generatePreview() : request.generate()) == true)
                #expect(session.candidates.filter { !$0.isPartial && !$0.isLiteral && $0.lexicalTokenCount != 1 }.count >= 6)
                var selection = CandidateSelection()
                selection.update(session.candidates)
                selection.setExpanded(expanded)
                #expect(selection.candidates.prefix(4).map(\.id) == session.candidates.prefix(4).map(\.id))
                #expect(selection.candidates.prefix(4).allSatisfy { !$0.isPartial && !$0.isMixed && $0.lexicalTokenCount != 1 })
                let later = selection.candidates.dropFirst(4).filter { !$0.isLiteral }
                #expect(!later.isEmpty)
                #expect(later.allSatisfy { $0.lexicalTokenCount == 1 && !$0.isMixed && !$0.hasLiteralSegments })
                #expect(selection.candidates.last?.isLiteral == true)
                let wordIndex = try #require(selection.candidates.firstIndex { $0.text == "明天" && $0.isPartial })
                #expect(wordIndex >= 4)
                selection.move(by: wordIndex)
                let word = try #require(selection.candidate(number: wordIndex % selection.visiblePageSize + 1))
                let view = CandidateListView()
                var clicked: String?
                view.onSelect = { clicked = $0 }
                view.render(selection)
                view.frame = NSRect(origin: .zero, size: view.preferredSize)
                view.layoutSubtreeIfNeeded()
                let row = try #require(view.rows.first { $0.candidateID == word.id })
                #expect(row.accessibilityLabel()?.contains("明天") == true)
                row.performClick(nil)
                #expect(clicked == word.id && word.text == "明天")
                let commit = session.commitResult(word, reason: .explicitSelection)
                #expect(commit.text == "明天" && commit.input == "mingtian")
                #expect(session.buffer == "womenqubeijing")
            }
        }
    }

    @MainActor
    @Test func continuousSentenceRendersAndCommitsFromTheFirstCellInBothLayouts() throws {
        for (input, expected) in [("mingtianwomenqubeijing", "明天我们去北京"), ("iwanttobuild", "I want to build")] {
            for preview in [true, false] {
                for expanded in [false, true] {
                    var session = InputSession(candidateGeneration: .deferred)
                    session.append(input)
                    let request = try #require(session.pendingCandidateRequest)
                    #expect(session.accept(preview ? request.generatePreview() : request.generate()) == true)
                    var selection = CandidateSelection()
                    selection.update(session.candidates)
                    selection.setExpanded(expanded)
                    let first = try #require(selection.candidate(number: 1))
                    #expect(first.text == expected && !first.isPartial)
                    #expect(selection.confirmationReason(for: first) == .defaultAcceptance)
                    let view = CandidateListView()
                    var clicked: String?
                    view.onSelect = { clicked = $0 }
                    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                        view.appearance = NSAppearance(named: appearance)
                        view.render(selection)
                        view.frame = NSRect(origin: .zero, size: view.preferredSize)
                        view.layoutSubtreeIfNeeded()
                        let row = try #require(view.rows.first)
                        #expect(row.candidateID == first.id && row.accessibilityLabel()?.contains(expected) == true)
                        row.performClick(nil)
                        #expect(clicked == first.id)
                    }
                    let commit = session.commitResult(first, reason: selection.confirmationReason(for: first))
                    #expect(commit.text == expected && commit.input == input && session.buffer.isEmpty)
                }
            }
        }
    }

    @Test func bufenciMixedCompletionNeedsItsScoreToReachTheRankedHead() throws {
        for input in ["bufenci", "bufencity"] {
            for preview in [true, false] {
                var session = InputSession(candidateGeneration: .deferred)
                session.configure(languages: Set(InputLanguage.allCases))
                session.append(input)
                let request = try #require(session.pendingCandidateRequest)
                let result = preview ? request.generatePreview() : request.generate()
                let accepted = session.accept(result)
                #expect(accepted)
                let mixed = try #require(result.candidates.first { $0.text == "部分 city" && $0.isMixed && !$0.isPartial })
                #expect(mixed.hasCompletion == (input == "bufenci"))
                var selection = CandidateSelection()
                selection.update(session.candidates)
                for expanded in [false, true] {
                    selection.setExpanded(expanded)
                    let head = session.candidates.filter { !$0.isLiteral }.prefix(4)
                    #expect(selection.candidates.contains(mixed) == head.contains(mixed))
                    #expect(selection.candidates.prefix(4).map(\.id) == head.map(\.id))
                    #expect(selection.candidates.last?.text == input && selection.candidates.last?.isLiteral == true)
                    #expect(result.candidates.contains { $0.language == .english && !$0.isMixed })
                }
                let chosen = try #require(selection.candidate(number: 4))
                let consumed = chosen.consumedInputCount ?? input.count
                let commit = session.commitResult(chosen, reason: .explicitSelection)
                #expect(commit.text == chosen.text && commit.input == String(input.prefix(consumed)))
                #expect(session.buffer == String(input.dropFirst(consumed)))
            }
        }
    }

    @MainActor
    @Test func fourthRankedChoiceRendersAndMouseSelectionCommitsItsConsumedSpelling() throws {
        for preview in [true, false] {
            for expanded in [false, true] {
                var session = InputSession(candidateGeneration: .deferred)
                session.configure(languages: Set(InputLanguage.allCases))
                session.append("bufenci")
                let request = try #require(session.pendingCandidateRequest)
                let accepted = session.accept(preview ? request.generatePreview() : request.generate())
                #expect(accepted)
                var selection = CandidateSelection()
                selection.update(session.candidates)
                selection.setExpanded(expanded)
                let fourth = try #require(selection.candidate(number: 4))
                #expect(fourth.id == session.candidates.filter { !$0.isLiteral }[3].id)
                let view = CandidateListView()
                var clicked: String?
                view.onSelect = { clicked = $0 }
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    view.appearance = NSAppearance(named: appearance)
                    view.render(selection)
                    view.frame = NSRect(origin: .zero, size: view.preferredSize)
                    view.layoutSubtreeIfNeeded()
                    let row = try #require(view.rows.first { $0.candidateID == fourth.id })
                    #expect(!row.candidateLabel.isHidden && row.accessibilityLabel()?.contains(fourth.text) == true)
                    row.performClick(nil)
                    #expect(clicked == fourth.id)
                }
                let chosen = try #require(session.candidates.first { $0.id == clicked })
                let commit = session.commitResult(chosen, reason: .explicitSelection)
                let consumed = fourth.consumedInputCount ?? "bufenci".count
                #expect(commit.text == fourth.text && commit.input == String("bufenci".prefix(consumed)))
                #expect(session.buffer == String("bufenci".dropFirst(consumed)))
            }
        }
    }

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
                #expect(selection.candidates.contains {
                    $0.text == "ability" && $0.language == .english && !$0.isPartial && $0.hasCompletion
                })
                #expect(selection.candidates.last?.isLiteral == true)
            }
        }
        let ability = try #require(session.candidates.first { $0.text == "ability" && $0.language == .english && !$0.isPartial })
        let commit = session.commitResult(ability, reason: .explicitSelection)
        #expect(commit.text == "ability" && commit.input == "abilit")
    }

    @Test func lowRankedCompleteEnglishWordHasNoReservationOverHigherRankedWords() {
        let prefix = InputCandidate(text: "a", language: .english, score: 100, consumedInputCount: 1, lexicalTokenCount: 1)
        let chinese = (0..<40).map { InputCandidate(text: "测试\($0)", language: .simplifiedChinese, score: 99 - $0, lexicalTokenCount: 1) }
        let english = InputCandidate(text: "ability", language: .english, score: -10, hasCompletion: true, lexicalTokenCount: 1)
        let literal = InputCandidate(text: "abilit", language: nil, score: 0)
        var selection = CandidateSelection()
        selection.update([prefix] + chinese + [english, literal])
        #expect(selection.candidates.count == CandidateShortlist.ordinaryCandidateLimit)
        #expect(!selection.candidates.contains { $0.id == english.id })
        #expect(selection.candidates == [prefix] + Array(chinese.prefix(25)) + [literal])
        #expect(selection.candidates.contains { $0.id == literal.id })
        #expect(selection.candidates.contains { $0.id == chinese[0].id })
    }
}
