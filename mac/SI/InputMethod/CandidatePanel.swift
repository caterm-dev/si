import AppKit
#if SWIFT_PACKAGE
import SILocalization
#endif

@MainActor
final class CandidatePanel: NSPanel {
    // Only visibility ownership is shared. Composition, candidates and selection stay
    // client-local. IMK may create several controllers without paired deactivation.
    private static weak var presentationOwner: CandidatePanel?
    var ownsPresentation: Bool { Self.presentationOwner === self }

    func claimPresentation() {
        if let previous = Self.presentationOwner, previous !== self { previous.orderOut(nil) }
        Self.presentationOwner = self
    }

    func releasePresentation() {
        orderOut(nil)
        if ownsPresentation { Self.presentationOwner = nil }
    }

    let list = CandidateListView()
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        contentView = list
        isReleasedWhenClosed = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        setAccessibilityLabel(L10n.text("SI candidates"))
    }

    func show(selection: CandidateSelection, caret: NSRect, clientLevel: Int, screens: [CandidatePlacement.Screen],
              isPending: Bool = false, refreshPendingRows: Bool = false) {
        guard ownsPresentation else { return }
        guard !selection.candidates.isEmpty else { orderOut(nil); return }
        // A hidden panel belongs to a finished composition; never retain its old rows.
        if !isVisible && isPending { list.render(selection) }
        list.render(selection, isPending: isPending, refreshPendingRows: refreshPendingRows)
        guard let frame = CandidatePlacement.frame(preferredSize: list.preferredSize, anchor: caret, screens: screens) else {
            orderOut(nil)
            return
        }
        level = NSWindow.Level(rawValue: max(NSWindow.Level.popUpMenu.rawValue, clientLevel))
        if self.frame != frame { setFrame(frame, display: false) }
        // Finish row layout at the new size before making the card visible. Painting
        // the resized window synchronously can expose the old row geometry for a frame.
        list.layoutSubtreeIfNeeded()
        if !isVisible { orderFrontRegardless() }
    }
}
