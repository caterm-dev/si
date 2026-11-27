import AppKit
import Testing
@testable import SICore
@testable import SIPresentation

@MainActor
struct CandidatePanelOwnershipTests {
    @Test func changingRowsAndExpansionKeepThePanelAtTheCapturedStart() throws {
        _ = NSApplication.shared
        let panel = CandidatePanel()
        defer { panel.releasePresentation(); panel.close() }
        panel.claimPresentation()
        let screen = CandidatePlacement.Screen(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                               visibleFrame: CGRect(x: 0, y: 40, width: 1440, height: 835))
        let anchor = try #require(CandidateAnchor(CGRect(x: 100, y: 400, width: 1, height: 20), screens: [screen]))
        var selection = CandidateSelection()
        selection.update([InputCandidate(text: "Synthetic", language: .english, score: 1)])
        panel.render(selection: selection)
        panel.show(at: anchor, clientLevel: 0)
        let compactSize = panel.frame.size

        selection.update((0..<12).map {
            InputCandidate(text: "Long synthetic candidate \($0)", language: .english, score: 12 - $0,
                           lexicalTokenCount: 1)
        })
        selection.setExpanded(true)
        panel.render(selection: selection)
        panel.show(at: anchor, clientLevel: 0)
        #expect(panel.frame.minX == 100 && panel.frame.maxY == 400)
        #expect(panel.frame.width > compactSize.width && panel.frame.height > compactSize.height)
    }

    @Test func visibleExpansionFlipsAboveAndCollapseReturnsBelowWithoutChangingSelection() throws {
        _ = NSApplication.shared
        let panel = CandidatePanel()
        defer { panel.releasePresentation(); panel.close() }
        panel.claimPresentation()
        let screen = CandidatePlacement.Screen(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                               visibleFrame: CGRect(x: 0, y: 40, width: 1440, height: 835))
        let anchor = try #require(CandidateAnchor(CGRect(x: 100, y: 80, width: 1, height: 20), screens: [screen]))
        var selection = CandidateSelection()
        selection.update((0..<18).map {
            InputCandidate(text: "Choice \($0)", language: .english, score: 100 - $0, lexicalTokenCount: 1)
        })
        selection.move(by: 2)
        let selected = try #require(selection.selected)
        let candidateIDs = selection.candidates.map(\.id)
        panel.fit(selection: &selection, at: anchor)
        panel.show(at: anchor, clientLevel: 0)
        let compact = panel.frame
        #expect(compact.maxY == anchor.rect.minY)

        for _ in 0..<2 {
            selection.setExpanded(true)
            // A visible panel must flip during fit, before deferred host positioning.
            panel.fit(selection: &selection, at: anchor)
            #expect(panel.frame.minY == anchor.rect.maxY && panel.frame.height > compact.height)
            #expect(panel.frame.height == panel.list.preferredSize(constrainedTo: panel.frame.width).height)
            #expect(screen.visibleFrame.contains(panel.frame))
            for row in panel.list.rows { #expect(panel.list.bounds.contains(row.frame)) }
            #expect(panel.list.bounds.contains(panel.list.expandButton.frame))
            #expect(selection.selected == selected && selection.candidates.map(\.id) == candidateIDs)
            let expanded = panel.frame
            panel.show(at: anchor, clientLevel: 0)
            #expect(panel.frame == expanded && panel.isVisible && !panel.canBecomeKey)

            selection.setExpanded(false)
            panel.fit(selection: &selection, at: anchor)
            #expect(panel.frame == compact && selection.selected == selected)
        }
    }

    @Test func onlyTheCurrentClientPanelCanOwnPresentation() {
        _ = NSApplication.shared
        let first = CandidatePanel()
        let second = CandidatePanel()
        defer { first.releasePresentation(); second.releasePresentation(); first.close(); second.close() }
        first.claimPresentation()
        #expect(first.ownsPresentation && !second.ownsPresentation)
        second.claimPresentation()
        #expect(!first.ownsPresentation && second.ownsPresentation)
        // A late deactivation of the old client cannot clear the new owner's lease.
        first.releasePresentation()
        #expect(second.ownsPresentation)
        second.releasePresentation()
        #expect(!first.ownsPresentation && !second.ownsPresentation)
    }

    @Test func aLateUpdateFromAnotherClientCannotRenderOrShowItsPanel() throws {
        _ = NSApplication.shared
        let stale = CandidatePanel()
        let active = CandidatePanel()
        defer { stale.releasePresentation(); active.releasePresentation(); stale.close(); active.close() }
        var selection = CandidateSelection()
        selection.update([InputCandidate(text: "Synthetic", language: .english, score: 1)])
        let screen = CandidatePlacement.Screen(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                               visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875))
        let anchor = try #require(CandidateAnchor(CGRect(x: 100, y: 100, width: 1, height: 20), screens: [screen]))
        // Render while this panel owns presentation, then let a focus switch precede its deferred show.
        stale.claimPresentation()
        stale.render(selection: selection)
        active.claimPresentation()
        stale.show(at: anchor, clientLevel: 0)
        #expect(!stale.isVisible && stale.list.rows.count == 1)
        selection.update([])
        stale.render(selection: selection)
        #expect(stale.list.rows.count == 1)
        #expect(!active.isVisible && active.list.rows.isEmpty)
        #expect(active.ownsPresentation)
    }
}
