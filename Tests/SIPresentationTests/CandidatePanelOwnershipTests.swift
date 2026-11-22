import AppKit
import Testing
@testable import SICore
@testable import SIPresentation

@MainActor
struct CandidatePanelOwnershipTests {
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
