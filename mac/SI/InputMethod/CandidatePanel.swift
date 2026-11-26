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
    var onLosePresentation: (() -> Void)?

    func claimPresentation() {
        if let previous = Self.presentationOwner, previous !== self {
            previous.orderOut(nil)
            previous.onLosePresentation?()
        }
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

    func render(selection: CandidateSelection, prediction: String? = nil, predictionStatus: String? = nil) {
        guard ownsPresentation else { return }
        list.render(selection, prediction: prediction, predictionStatus: predictionStatus)
    }

    func fit(selection: inout CandidateSelection, at anchor: CandidateAnchor,
             prediction: String? = nil, predictionStatus: String? = nil) {
        guard ownsPresentation else { return }
        let count = list.fittingPageSize(for: selection, maximumWidth: CandidatePlacement.availableWidth(at: anchor))
        selection.setPageSize(count)
        render(selection: selection, prediction: prediction, predictionStatus: predictionStatus)
        // A visible panel can repaint before deferred host geometry arrives. Fit
        // its new text at the retained anchor instead of using the old width.
        if isVisible { _ = updateLayout(at: anchor) }
    }

    func show(at anchor: CandidateAnchor, clientLevel: Int) {
        guard ownsPresentation, !list.rows.isEmpty else { return }
        level = NSWindow.Level(rawValue: max(NSWindow.Level.popUpMenu.rawValue, clientLevel))
        guard updateLayout(at: anchor) else { return }
        if !isVisible { orderFrontRegardless() }
    }

    private func updateLayout(at anchor: CandidateAnchor) -> Bool {
        let size = list.preferredSize(constrainedTo: CandidatePlacement.availableWidth(at: anchor))
        guard let frame = CandidatePlacement.frame(preferredSize: size, anchor: anchor) else {
            orderOut(nil)
            return false
        }
        if self.frame != frame { setFrame(frame, display: false) }
        // Finish row layout at the new size before making the card visible. Painting
        // the resized window synchronously can expose the old row geometry for a frame.
        list.layoutSubtreeIfNeeded()
        return true
    }
}
