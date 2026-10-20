import AppKit

@MainActor
final class CandidatePanel: NSPanel {
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
        setAccessibilityLabel("SI candidates")
    }

    func show(selection: CandidateSelection, caret: NSRect, clientLevel: Int, screens: [CandidatePlacement.Screen],
              isPending: Bool = false, refreshPendingRows: Bool = false) {
        guard !selection.candidates.isEmpty else { orderOut(nil); return }
        // A hidden panel belongs to a finished composition; never retain its old rows.
        if !isVisible && isPending { list.render(selection) }
        list.render(selection, isPending: isPending, refreshPendingRows: refreshPendingRows)
        guard let frame = CandidatePlacement.frame(preferredSize: list.preferredSize, anchor: caret, screens: screens) else {
            orderOut(nil)
            return
        }
        level = NSWindow.Level(rawValue: max(NSWindow.Level.popUpMenu.rawValue, clientLevel))
        if self.frame != frame { setFrame(frame, display: true) }
        if !isVisible { orderFrontRegardless() }
    }
}
