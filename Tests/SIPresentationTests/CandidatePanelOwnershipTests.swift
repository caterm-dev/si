import AppKit
import Testing
import SICore
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

    @Test func aLateUpdateFromAnotherClientCannotRenderOrShowItsPanel() {
        _ = NSApplication.shared
        let stale = CandidatePanel()
        let active = CandidatePanel()
        defer { stale.releasePresentation(); active.releasePresentation(); stale.close(); active.close() }
        stale.claimPresentation()
        active.claimPresentation()
        var selection = CandidateSelection()
        selection.update([InputCandidate(text: "Synthetic", language: .english, score: 1)])
        stale.show(selection: selection, caret: CGRect(x: 0, y: 0, width: 1, height: 20), clientLevel: 0,
                   screens: [CandidatePlacement.Screen(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                                        visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875))])
        #expect(!stale.isVisible && stale.list.rows.isEmpty)
        #expect(active.ownsPresentation)
    }
}
