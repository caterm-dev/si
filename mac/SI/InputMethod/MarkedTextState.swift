import Foundation

/// Last host update for one client/composition. Candidate deliveries resend marked
/// text only when its displayed spelling/segmentation or UTF-16 caret changes.
struct MarkedTextState {
    private(set) var text: String?
    private var selection: NSRange?

    mutating func shouldSend(_ text: String, selection: NSRange) -> Bool {
        guard self.selection != selection || self.text?.utf8.elementsEqual(text.utf8) != true else { return false }
        self.text = text
        self.selection = selection
        return true
    }

    mutating func reset() {
        text = nil
        selection = nil
    }
}
