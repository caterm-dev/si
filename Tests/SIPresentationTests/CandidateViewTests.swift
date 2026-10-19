import AppKit
import Testing
import SICore
@testable import SIPresentation

@MainActor
struct CandidateViewTests {
    @Test func realKeyEventValuesDriveTheDisplayedSelectionAndCommit() throws {
        var session = InputSession()
        session.append("shi")
        var selection = CandidateSelection()
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
        selection.update([
            InputCandidate(text: "你好 world", language: .english, score: 100, isMixed: true),
            InputCandidate(text: "你好，世界", language: .simplifiedChinese, score: 100),
            InputCandidate(text: "hello world", language: .english, score: 100),
        ] + (0..<9).map { InputCandidate(text: "测试候选\($0 + 1)", language: .simplifiedChinese, score: 100) })
        selection.move(by: 1)
        let view = CandidateListView()
        view.render(selection)
        let light = try snapshot(view, appearance: .aqua)
        let dark = try snapshot(view, appearance: .darkAqua)
        if let path = ProcessInfo.processInfo.environment["SI_CANDIDATE_SNAPSHOT_PATH"] {
            let location = URL(filePath: path)
            try light.write(to: location)
            try dark.write(to: location.deletingPathExtension().appendingPathExtension("dark.png"))
            selection.update(Array(selection.candidates.prefix(3)))
            view.render(selection)
            try snapshot(view, appearance: .aqua).write(to: location.deletingPathExtension().appendingPathExtension("compact.png"))
        }
    }

    private func snapshot(_ view: CandidateListView, appearance: NSAppearance.Name) throws -> Data {
        view.appearance = NSAppearance(named: appearance)
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
        #expect(!row.detailLabel.isHidden)
        #expect(row.detailLabel.stringValue == "First 5")
        let literal = InputCandidate(text: "NiHao", language: nil, score: 0)
        row.configure(candidate: literal, number: 3, selected: false)
        #expect(row.detailLabel.stringValue == "As Typed")
    }

    @Test func compactSinglePageHidesFooterAndPageButtonsStillNavigate() {
        let candidates = (0..<11).map { InputCandidate(text: "词\($0)", language: .simplifiedChinese, score: 100) }
        var selection = CandidateSelection()
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
