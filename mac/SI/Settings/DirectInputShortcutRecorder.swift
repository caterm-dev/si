import AppKit
import SwiftUI

struct DirectInputShortcutRecorder: NSViewRepresentable {
    let onRecord: (DirectInputShortcut) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> CaptureView {
        let view = CaptureView()
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.group)
        view.setAccessibilityLabel(L10n.text("Record Direct Input Shortcut"))
        view.setAccessibilityHelp(L10n.text("Press a letter, number or punctuation key with Control, Option or Command. Escape cancels."))
        view.onRecord = onRecord
        view.onCancel = onCancel
        return view
    }

    func updateNSView(_ view: CaptureView, context: Context) {
        view.onRecord = onRecord
        view.onCancel = onCancel
    }

    final class CaptureView: NSView {
        var onRecord: ((DirectInputShortcut) -> Void)?
        var onCancel: (() -> Void)?
        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            Task { @MainActor [weak self] in
                guard let self, let window = self.window else { return }
                window.makeFirstResponder(self)
            }
        }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { onCancel?(); return }
            if let shortcut = DirectInputShortcut.recording(event) { onRecord?(shortcut); return }
            if event.keyCode == 48 { super.keyDown(with: event) }
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard window?.firstResponder === self else { return false }
            keyDown(with: event)
            return true
        }
    }
}
