import AppKit
import Testing
import SICore
@testable import SIPresentation

@MainActor
struct CandidateViewTests {
    @Test(arguments: [false, true])
    func unchangedPreviewAndFinalResultsKeepTheExistingRows(expanded: Bool) {
        var selection = CandidateSelection()
        selection.setExpanded(expanded)
        selection.update([
            InputCandidate(text: "今天", language: .simplifiedChinese, score: 100),
            InputCandidate(text: "尽头", language: .simplifiedChinese, score: 90),
        ])
        let view = CandidateListView()
        view.render(selection)
        let rows = view.rows
        view.render(selection, isPending: true, refreshPendingRows: true)
        #expect(view.rows.elementsEqual(rows, by: { $0 === $1 }))
        #expect(view.rows.allSatisfy { !$0.isEnabled })
        view.render(selection)
        #expect(view.rows.elementsEqual(rows, by: { $0 === $1 }))
        #expect(view.rows.allSatisfy { $0.isEnabled })
        selection.move(by: 1)
        view.render(selection)
        #expect(view.rows.elementsEqual(rows, by: { $0 === $1 }))
        #expect(view.rows[1].isCurrent && !view.rows[0].isCurrent)
    }

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func singleLetterCandidateRemainsVisibleAndSelectable(appearance: NSAppearance.Name) throws {
        var session = InputSession()
        session.append("a")
        var selection = CandidateSelection()
        selection.update(session.candidates)
        let view = CandidateListView()
        var clicked: String?
        view.onSelect = { clicked = $0 }
        for expanded in [false, true] {
            selection.setExpanded(expanded)
            view.render(selection)
            let image = try snapshot(view, appearance: appearance)
            let first = try #require(view.rows.first)
            #expect(first.candidateLabel.stringValue == "a")
            #expect(!first.candidateLabel.isHidden)
            #expect(first.candidateLabel.frame.width >= first.candidateLabel.intrinsicContentSize.width)
            first.performClick(nil)
            #expect(clicked == selection.candidate(number: 1)?.id)
            #expect(selection.candidate(number: 1)?.text == "a")
            if !expanded, let path = ProcessInfo.processInfo.environment["SI_SHORT_CANDIDATE_SNAPSHOT_PATH"] {
                let suffix = appearance == .darkAqua ? "dark" : "light"
                try image.write(to: URL(filePath: "\(path).\(suffix).png"))
            }
        }
    }

    @Test(arguments: [false, true], [false, true])
    func scrollingNeverChangesCandidatePages(expanded: Bool, pending: Bool) throws {
        var selection = CandidateSelection()
        selection.setExpanded(expanded)
        selection.update((0..<27).map { InputCandidate(text: "Synthetic \($0)", language: .english, score: 100) })
        selection.movePage(by: 1)
        let selected = selection.selected
        let view = CandidateListView()
        view.render(selection, isPending: pending)
        var pageMoves: [Int] = []
        view.onMovePage = {
            pageMoves.append($0)
            selection.movePage(by: $0)
        }
        for units in [CGScrollEventUnit.line, .pixel] {
            for (vertical, horizontal): (Int32, Int32) in [(20, 0), (-20, 0), (0, 20), (0, -20)] {
                let scroll = try #require(CGEvent(scrollWheelEvent2Source: nil, units: units, wheelCount: 2,
                                                 wheel1: vertical, wheel2: horizontal, wheel3: 0))
                let event = try #require(NSEvent(cgEvent: scroll))
                view.scrollWheel(with: event)
            }
        }
        #expect(pageMoves.isEmpty)
        #expect(selection.selected == selected && selection.page == 1)
    }

    @Test(arguments: [false, true])
    func freshPendingHintsReplaceOldRowsWithoutShrinkingOrEnablingStaleActions(expanded: Bool) throws {
        var selection = CandidateSelection()
        selection.setExpanded(expanded)
        selection.update((0..<9).map { InputCandidate(text: "Previous long synthetic candidate \($0)", language: .english, score: 100) })
        let view = CandidateListView()
        view.render(selection)
        let old = view.rows[0]
        let size = view.preferredSize
        var selected: [String] = []
        view.onSelect = { selected.append($0) }
        for text in ["你", "你好", "你好朋友"] {
            selection.update([InputCandidate(text: text, language: .simplifiedChinese, score: 100)])
            view.render(selection, isPending: true, refreshPendingRows: true)
            #expect(view.rows[0].candidateLabel.stringValue == text)
            #expect(view.preferredSize == size)
            #expect(view.isUpdating && !view.rows[0].isEnabled && !view.expandButton.isEnabled)
            NSApplication.shared.sendAction(try #require(old.action), to: view, from: old)
            NSApplication.shared.sendAction(try #require(view.rows[0].action), to: view, from: view.rows[0])
        }
        #expect(selected.isEmpty)
        view.render(selection)
        #expect(!view.isUpdating && view.rows[0].isEnabled)
        #expect(view.preferredSize.width <= size.width && view.preferredSize.height <= size.height)
        old.performClick(nil)
        #expect(selected.isEmpty)
        view.rows[0].performClick(nil)
        #expect(selected == [selection.candidates[0].id])
    }

    @Test func compactRowsShareOneLineAndExpansionPreservesMouseAndNumberMapping() throws {
        var selection = CandidateSelection()
        selection.update((0..<22).map { InputCandidate(text: "测试候选\($0)", language: .simplifiedChinese, score: 100) })
        let view = CandidateListView()
        var clicked: String?
        view.onSelect = { clicked = $0 }
        view.onToggleExpansion = {
            selection.setExpanded(!selection.isExpanded)
            view.render(selection)
        }
        view.render(selection)
        view.frame = NSRect(origin: .zero, size: view.preferredSize)
        view.layoutSubtreeIfNeeded()
        #expect(view.rows.count == 5 && view.preferredSize.height < 40)
        #expect(view.rows.map { $0.numberLabel.stringValue } == ["1", "2", "3", "4", "5"])
        #expect(Set(view.rows.map { $0.frame.minY }).count == 1)
        #expect(view.rows[0].frame.maxX <= view.rows[1].frame.minX)
        #expect(view.rows.last!.frame.maxX <= view.expandButton.frame.minX)
        #expect(view.pageLabel.isHidden && view.previousButton.isHidden && view.nextButton.isHidden)
        #expect(view.expandButton.accessibilityLabel() == "Expand candidates")
        view.rows[2].performClick(nil)
        #expect(clicked == selection.candidate(number: 3)?.id)
        view.rows[4].performClick(nil)
        #expect(clicked == selection.candidate(number: 5)?.id)
        selection.move(by: 7)
        view.render(selection)
        let selected = selection.selected
        view.expandButton.performClick(nil)
        #expect(selection.isExpanded && view.isExpanded && view.rows.count == 9)
        #expect(selection.selected == selected)
        #expect(view.rows[7].isCurrent)
        #expect(view.expandButton.accessibilityLabel() == "Collapse candidates")
        view.expandButton.performClick(nil)
        #expect(!view.isExpanded && selection.selected == selected)
        #expect(view.rows[2].isCurrent)
        view.rows[2].performClick(nil)
        #expect(clicked == selection.candidate(number: 3)?.id)
        // Narrow host screens clip labels, without overlapping controls or changing commit identity.
        view.frame.size.width = 220
        view.layoutSubtreeIfNeeded()
        #expect(view.rows.allSatisfy { $0.frame.minX >= 0 && $0.frame.maxX <= view.expandButton.frame.minX })
        // Retaining a wide pending window must not stretch the selected pill into empty space.
        view.frame.size.width = 800
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        // AppKit's frame conversion can introduce fractional floating-point roundoff.
        for row in view.rows { #expect(row.frame.width <= row.preferredWidth + 0.001) }
    }

    @Test(arguments: [false, true])
    func pendingSearchKeepsTheCardUntilCurrentCandidatesReplaceIt(expanded: Bool) throws {
        let view = CandidateListView()
        var selection = CandidateSelection()
        selection.setExpanded(expanded)
        selection.update((0..<12).map { InputCandidate(text: "旧候选\($0)", language: .simplifiedChinese, score: 100) })
        view.render(selection)
        let oldRows = view.rows
        let size = view.preferredSize
        let pageText = view.pageLabel.stringValue
        var selected: [String] = []
        var pageMoves: [Int] = []
        var expansions = 0
        view.onSelect = { selected.append($0) }
        view.onMovePage = { pageMoves.append($0) }
        view.onToggleExpansion = { expansions += 1 }

        // Deferred sessions expose only the current literal until their result arrives.
        for spelling in ["n", "ni", "nihao"] {
            selection.update([InputCandidate(text: spelling, language: nil, score: 0)])
            view.render(selection, isPending: true)
            #expect(view.preferredSize == size)
            #expect(view.rows.elementsEqual(oldRows, by: { $0 === $1 }))
            #expect(view.pageLabel.stringValue == pageText)
            #expect(view.rows.allSatisfy { !$0.isEnabled })
            #expect(!view.previousButton.isEnabled && !view.nextButton.isEnabled)
            #expect(!view.expandButton.isEnabled)
            // Also reject actions already queued before the controls were disabled.
            NSApplication.shared.sendAction(try #require(oldRows[0].action), to: view, from: oldRows[0])
            NSApplication.shared.sendAction(try #require(view.nextButton.action), to: view, from: view.nextButton)
            NSApplication.shared.sendAction(try #require(view.expandButton.action), to: view, from: view.expandButton)
        }
        #expect(selected.isEmpty && pageMoves.isEmpty)
        #expect(expansions == 0)
        #expect(view.accessibilityHelp() == "Updating candidates")

        selection.update([InputCandidate(text: "你好", language: .simplifiedChinese, score: 100)])
        view.render(selection)
        #expect(!view.isUpdating)
        #expect(view.accessibilityHelp() == nil)
        #expect(view.rows[0].isEnabled)
        #expect(view.rows[0].candidateLabel.stringValue == "你好")
        #expect(!view.showsPagination)
        oldRows[0].performClick(nil)
        #expect(selected.isEmpty)
        view.rows[0].performClick(nil)
        #expect(selected == [selection.candidates[0].id])
    }

    @Test func firstPendingCompositionShowsItsLiteralWithoutEnablingSelection() {
        let view = CandidateListView()
        var selection = CandidateSelection()
        selection.setExpanded(true)
        selection.update([InputCandidate(text: "Ni", language: nil, score: 0)])
        view.render(selection, isPending: true)
        #expect(view.rows.map { $0.candidateLabel.stringValue } == ["Ni"])
        #expect(!view.rows[0].isEnabled)
        selection.update([])
        view.render(selection)
        #expect(view.rows.isEmpty && !view.isUpdating)
        selection.update([InputCandidate(text: "Other", language: nil, score: 0)])
        view.render(selection, isPending: true)
        #expect(view.rows.map { $0.candidateLabel.stringValue } == ["Other"])
    }

    @Test func aRemovedRowCannotSelectAReplacementCompositionsCandidate() {
        let view = CandidateListView()
        var selection = CandidateSelection()
        selection.setExpanded(true)
        var selected: [String] = []
        view.onSelect = { selected.append($0) }
        selection.update([InputCandidate(text: "旧", language: .simplifiedChinese, score: 100)])
        view.render(selection)
        let oldRow = view.rows[0]
        selection.update([InputCandidate(text: "新", language: .simplifiedChinese, score: 100)])
        view.render(selection)
        oldRow.performClick(nil)
        #expect(selected.isEmpty)
        view.rows[0].performClick(nil)
        #expect(selected == [selection.candidates[0].id])
    }

    @Test func realKeyEventValuesDriveTheDisplayedSelectionAndCommit() throws {
        var session = InputSession()
        session.append("shi")
        var selection = CandidateSelection()
        selection.setExpanded(true)
        selection.update(session.candidates)
        let view = CandidateListView()
        let down = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                               windowNumber: 0, context: nil, characters: "\u{F701}",
                                               charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: 125))
        let action = CandidateSelection.action(keyCode: down.keyCode, characters: down.characters)
        #expect(action == .move(1))
        if case .move(let offset) = action { selection.move(by: offset) }
        view.render(selection)
        #expect(view.rows[1].isCurrent)
        let digit = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                windowNumber: 0, context: nil, characters: "2",
                                                charactersIgnoringModifiers: "2", isARepeat: false, keyCode: 19))
        let digitAction = CandidateSelection.action(keyCode: digit.keyCode, characters: digit.characters)
        #expect(digitAction == .choose(2))
        guard case .choose(let number) = digitAction else { return }
        let candidate = try #require(selection.candidate(number: number))
        #expect(candidate.id == view.rows[1].candidateID)
        let commit = session.commitResult(candidate, reason: .explicitSelection)
        #expect(commit.text == view.rows[1].candidateLabel.stringValue)
        #expect(session.buffer.isEmpty)
        #expect(CandidateSelection.action(keyCode: 18, characters: "!") == nil)
        #expect(CandidateSelection.action(keyCode: 29, characters: "0") == nil)
        #expect(CandidateSelection.action(keyCode: 123, characters: "\u{F702}") == nil)
        #expect(CandidateSelection.action(keyCode: 126, characters: "\u{F700}") == .move(-1))
        #expect(CandidateSelection.action(keyCode: 121, characters: "\u{F72D}") == .move(9))
        #expect(CandidateSelection.action(keyCode: 116, characters: "\u{F72C}") == .move(-9))
    }

    @Test func syntheticCandidateViewCanRenderForVisualInspection() throws {
        var selection = CandidateSelection()
        selection.setExpanded(true)
        selection.update([
            InputCandidate(text: "然后有一个展开的按钮", language: .simplifiedChinese, score: 100, hasCompletion: true),
            InputCandidate(text: "然后有一个", language: .simplifiedChinese, score: 99),
            InputCandidate(text: "然后又", language: .simplifiedChinese, score: 74, consumedInputCount: 9),
            InputCandidate(text: "然后", language: .simplifiedChinese, score: 73, consumedInputCount: 6),
            InputCandidate(text: "然", language: .simplifiedChinese, score: 72, consumedInputCount: 3),
        ] + (0..<9).map { InputCandidate(text: "测试候选\($0 + 1)", language: .simplifiedChinese, score: 70 - $0) })
        let view = CandidateListView()
        view.render(selection)
        let light = try snapshot(view, appearance: .aqua)
        let dark = try snapshot(view, appearance: .darkAqua)
        if let path = ProcessInfo.processInfo.environment["SI_CANDIDATE_SNAPSHOT_PATH"] {
            let location = URL(filePath: path)
            try light.write(to: location)
            try dark.write(to: location.deletingPathExtension().appendingPathExtension("dark.png"))
            selection.setExpanded(false)
            view.render(selection)
            try snapshot(view, appearance: .aqua).write(to: location.deletingPathExtension().appendingPathExtension("compact.png"))
            try snapshot(view, appearance: .darkAqua).write(to: location.deletingPathExtension().appendingPathExtension("compact.dark.png"))
            view.frame.size.width = 280
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.appearance = NSAppearance(named: .aqua)
            view.effectiveAppearance.performAsCurrentDrawingAppearance {
                view.cacheDisplay(in: view.bounds, to: bitmap)
            }
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: location.deletingPathExtension().appendingPathExtension("narrow.png"))
        }
    }

    private func snapshot(_ view: CandidateListView, appearance: NSAppearance.Name) throws -> Data {
        view.appearance = try #require(NSAppearance(named: appearance))
        view.frame = NSRect(origin: .zero, size: view.preferredSize)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: bitmap)
        }
        #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    @Test func languageDescriptionIsHiddenVisuallyButRetainedForAccessibility() throws {
        let mixed = InputCandidate(text: "你好 world", language: .english, score: 100, isMixed: true)
        let row = CandidateRowButton()
        row.configure(candidate: mixed, number: 1, selected: false)
        #expect(row.detailLabel.isHidden)
        #expect(row.detailLabel.stringValue.isEmpty)
        #expect(row.candidateLabel.stringValue == mixed.text)
        #expect(row.accessibilityLabel()?.contains("Chinese + English") == true)
        #expect(row.toolTip?.contains("Chinese + English") == true)
        #expect(row.candidateID == mixed.id)
        let prefix = InputCandidate(text: "你好", language: .simplifiedChinese, score: 100, consumedInputCount: 5)
        row.configure(candidate: prefix, number: 2, selected: false)
        #expect(row.detailLabel.isHidden && row.detailLabel.stringValue.isEmpty)
        #expect(row.accessibilityLabel()?.contains("First 5 characters") == true)
        #expect(row.toolTip?.contains("First 5 characters") == true)
        row.configure(candidate: prefix, number: 2, selected: false, compact: true)
        #expect(row.detailLabel.isHidden && !row.sourceIndicator.isHidden)
        #expect(row.accessibilityLabel()?.contains("First 5 characters") == true)
        #expect(row.toolTip?.contains("First 5 characters") == true)
        #expect(row.candidateLabel.stringValue == prefix.text && row.candidateID == prefix.id)
        let literal = InputCandidate(text: "NiHao", language: nil, score: 0)
        row.configure(candidate: literal, number: 3, selected: false)
        #expect(row.detailLabel.stringValue == "As Typed")
    }

    @Test func compactSinglePageHidesFooterAndPageButtonsStillNavigate() {
        let candidates = (0..<11).map { InputCandidate(text: "词\($0)", language: .simplifiedChinese, score: 100) }
        var selection = CandidateSelection()
        selection.setExpanded(true)
        selection.update(Array(candidates.prefix(3)))
        let view = CandidateListView()
        view.render(selection)
        #expect(view.preferredSize.width < 300)
        #expect(!view.showsPagination)
        #expect(view.pageLabel.isHidden && view.previousButton.isHidden && view.nextButton.isHidden)
        selection.update(candidates)
        view.render(selection)
        #expect(view.showsPagination)
        #expect(view.pageLabel.stringValue == "1 / 2")
        #expect(!view.previousButton.isEnabled)
        var pageOffset: Int?
        view.onMovePage = { pageOffset = $0 }
        view.nextButton.performClick(nil)
        #expect(pageOffset == 1)
        #expect(view.nextButton.accessibilityLabel() == "Next page")
    }

    @Test func renderedNumbersHighlightAndKeyboardChoiceStayInSync() throws {
        var selection = CandidateSelection()
        selection.setExpanded(true)
        selection.update((0..<22).map { InputCandidate(text: "测试\($0)", language: .simplifiedChinese, score: 100) })
        let view = CandidateListView()
        view.render(selection)
        #expect(view.rows.map { $0.numberLabel.stringValue } == (1...9).map(String.init))
        #expect(view.rows.filter(\.isCurrent).map(\.candidateID) == [selection.selected?.id])
        selection.move(by: 1)
        view.render(selection)
        #expect(view.rows[1].isCurrent)
        #expect(!view.rows[0].isCurrent)
        #expect(view.rows[1].candidateID == selection.candidate(number: 2)?.id)
        selection.movePage(by: 1)
        view.render(selection)
        #expect(view.rows[0].candidateID == selection.candidate(number: 1)?.id)
        #expect(view.rows[1].isCurrent)
        #expect(view.rows[1].accessibilityValue() as? String == "Selected")
        selection.movePage(by: 1)
        view.render(selection)
        #expect(view.rows.count == 4)
        #expect(view.rows.map { $0.numberLabel.stringValue } == ["1", "2", "3", "4"])
    }

    @Test func mouseActionUsesTheSameCandidateIdentityAsItsNumber() throws {
        var selection = CandidateSelection()
        selection.setExpanded(true)
        selection.update((0..<20).map { InputCandidate(text: "word\($0)", language: .english, score: 100) })
        selection.movePage(by: 1)
        let view = CandidateListView()
        var clicked: String?
        view.onSelect = { clicked = $0 }
        view.render(selection)
        view.rows[1].performClick(nil)
        #expect(clicked == selection.candidate(number: 2)?.id)
        #expect(view.rows[1].accessibilityLabel()?.contains("word10") == true)
    }

    @Test func clearingTheViewRemovesStaleRowsAndFocusStaysWithHost() {
        var selection = CandidateSelection()
        selection.setExpanded(true)
        selection.update([InputCandidate(text: "你好", language: .simplifiedChinese, score: 100)])
        let view = CandidateListView()
        view.render(selection)
        #expect(!view.rows[0].acceptsFirstResponder)
        selection.update([])
        view.render(selection)
        #expect(view.rows.isEmpty)
        let panel = CandidatePanel()
        #expect(!panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(!panel.isVisible)
        panel.close()
    }
}
