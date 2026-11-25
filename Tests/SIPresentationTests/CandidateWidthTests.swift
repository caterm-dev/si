import AppKit
import Testing
import SICore
@testable import SIPresentation

@MainActor
struct CandidateWidthTests {
    @Test func thePanelReducesSixChoicesDownToOneBeforeTruncating() throws {
        _ = NSApplication.shared
        let panel = CandidatePanel()
        defer { panel.releasePresentation(); panel.close() }
        panel.claimPresentation()
        var selection = CandidateSelection()
        selection.update(choices())
        let expectedIDs = selection.candidates.map(\.id)
        let measure = CandidateListView()
        for count in stride(from: 6, through: 1, by: -1) {
            var trial = selection
            trial.setPageSize(count)
            measure.render(trial)
            let available = measure.preferredSize.width.rounded(.up)
            let anchor = try makeAnchor(availableWidth: available)
            panel.fit(selection: &selection, at: anchor)
            panel.show(at: anchor, clientLevel: 0)
            #expect(selection.visiblePageSize == count)
            #expect(panel.list.rows.count == count)
            #expect(selection.candidates.map(\.id) == expectedIDs)
            #expect(panel.frame.minX == 100 && panel.frame.maxY == 400)
            #expect(panel.frame.maxX <= anchor.screen.visibleFrame.maxX + 0.001)
            for (index, row) in panel.list.rows.enumerated() {
                #expect(row.numberLabel.stringValue == String(index + 1))
                #expect(row.candidateID == selection.candidate(number: index + 1)?.id)
                #expect(row.frame.maxX <= panel.list.expandButton.frame.minX)
                #expect(row.candidateLabel.frame.width >= row.candidateLabel.intrinsicContentSize.width)
            }
            if [6, 3, 1].contains(count) { try snapshot(panel.list, name: "compact-\(count)") }
        }
        let wide = try makeAnchor(availableWidth: 1300)
        panel.fit(selection: &selection, at: wide)
        #expect(selection.visiblePageSize == 6)
    }

    @Test func expandedRowsNumbersAndMouseClicksUseTheReducedColumnCount() throws {
        _ = NSApplication.shared
        let panel = CandidatePanel()
        defer { panel.releasePresentation(); panel.close() }
        panel.claimPresentation()
        var selection = CandidateSelection()
        selection.update(choices())
        selection.setExpanded(true)
        selection.move(by: 4)
        let chosen = try #require(selection.selected)
        var trial = selection
        trial.setPageSize(3)
        let measure = CandidateListView()
        measure.render(trial)
        let anchor = try makeAnchor(availableWidth: measure.preferredSize.width.rounded(.up))
        panel.fit(selection: &selection, at: anchor)
        panel.show(at: anchor, clientLevel: 0)
        #expect(selection.visiblePageSize == 3 && selection.selected == chosen)
        #expect(panel.list.rows.count == selection.displayedRange.count)
        #expect(panel.frame.maxX <= anchor.screen.visibleFrame.maxX + 0.001)
        var clicked: String?
        panel.list.onSelect = { clicked = $0 }
        for (index, row) in zip(selection.displayedRange, panel.list.rows) {
            #expect(row.numberLabel.stringValue == String(index % 3 + 1))
            #expect(row.isKeyboardRow == selection.visibleRange.contains(index))
            #expect(row.accessibilityHelp() != nil)
            row.performClick(nil)
            #expect(clicked == selection.candidates[index].id)
            if row.isKeyboardRow { #expect(clicked == selection.candidate(number: index % 3 + 1)?.id) }
            if index >= 3 {
                let column = panel.list.rows[index % 3]
                #expect(row.frame.minX == column.frame.minX && row.frame.width == column.frame.width)
            }
        }
        #expect(selection.candidates.last?.isLiteral == true)
        try snapshot(panel.list, name: "expanded-3")
    }

    @Test func oneOversizedChoiceKeepsItsExactTextAndFitsTheRemainingWidth() throws {
        _ = NSApplication.shared
        let panel = CandidatePanel()
        defer { panel.releasePresentation(); panel.close() }
        panel.claimPresentation()
        let text = String(repeating: "Synthetic long candidate ", count: 12)
        let candidate = InputCandidate(text: text, language: .english, score: 100, lexicalTokenCount: 1)
        var selection = CandidateSelection()
        selection.update([candidate] + choices())
        let anchor = try makeAnchor(availableWidth: 150)
        panel.fit(selection: &selection, at: anchor)
        panel.show(at: anchor, clientLevel: 0)
        #expect(selection.visiblePageSize == 1 && panel.list.rows.count == 1)
        #expect(panel.frame.width == 150 && panel.frame.minX == 100)
        let row = try #require(panel.list.rows.first)
        #expect(row.candidateLabel.frame.width < row.candidateLabel.intrinsicContentSize.width)
        #expect(row.candidateLabel.stringValue.utf8.elementsEqual(text.utf8))
        #expect(row.toolTip?.contains(text) == true && row.accessibilityLabel()?.contains(text) == true)
        #expect(selection.candidate(number: 1)?.text == text)
        try snapshot(panel.list, name: "oversized-1")
    }

    @Test func aShortSingleCandidateDoesNotReserveFiveEmptyColumns() {
        var selection = CandidateSelection()
        selection.update([InputCandidate(text: "一", language: .simplifiedChinese, score: 1, lexicalTokenCount: 1)])
        let view = CandidateListView()
        #expect(view.fittingPageSize(for: selection, maximumWidth: 100) == 6)
    }

    @Test func windowRoundingDoesNotOverflowFractionalRemainingWidth() throws {
        _ = NSApplication.shared
        let panel = CandidatePanel()
        defer { panel.releasePresentation(); panel.close() }
        panel.claimPresentation()
        var selection = CandidateSelection()
        selection.update(choices())
        let anchor = try makeAnchor(availableWidth: 401.5)
        panel.fit(selection: &selection, at: anchor)
        panel.show(at: anchor, clientLevel: 0)
        #expect(panel.frame.maxX <= anchor.screen.visibleFrame.maxX)
    }

    private func choices() -> [InputCandidate] {
        (0..<9).map { InputCandidate(text: "候选文字\($0)", language: .simplifiedChinese,
                                     score: 100 - $0, lexicalTokenCount: 1) }
            + [InputCandidate(text: "Exact_Bytes", language: nil, score: 0)]
    }

    private func makeAnchor(availableWidth: CGFloat) throws -> CandidateAnchor {
        let screen = CandidatePlacement.Screen(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                               visibleFrame: CGRect(x: 0, y: 40, width: 100 + availableWidth, height: 835))
        return try #require(CandidateAnchor(CGRect(x: 100, y: 400, width: 1, height: 20), screens: [screen]))
    }

    private func snapshot(_ view: CandidateListView, name: String) throws {
        guard let prefix = ProcessInfo.processInfo.environment["SI_ADAPTIVE_SNAPSHOT_PATH"] else { return }
        for style in [NSAppearance.Name.aqua, .darkAqua] {
            view.appearance = try #require(NSAppearance(named: style))
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.effectiveAppearance.performAsCurrentDrawingAppearance {
                view.cacheDisplay(in: view.bounds, to: bitmap)
            }
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            let suffix = style == .aqua ? "light" : "dark"
            try data.write(to: URL(filePath: "\(prefix).\(name).\(suffix).png"))
        }
    }
}
