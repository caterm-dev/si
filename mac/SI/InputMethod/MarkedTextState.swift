import Foundation

/// Last host update for one client/composition. Candidate deliveries resend marked
/// text only when its displayed spelling/segmentation or UTF-16 caret changes.
struct MarkedTextState {
    private(set) var text: String?
    private var selection: NSRange?
    var caretUTF16Offset: Int? { selection?.location }
    private(set) var candidateStart: CandidateAnchor?
    private(set) var didCaptureCandidateStart = false
    private(set) var candidateLineStartUTF16Offset = 0

    mutating func captureCandidateStart(_ rect: CGRect, screens: [CandidatePlacement.Screen]) {
        guard !didCaptureCandidateStart else { return }
        didCaptureCandidateStart = true
        candidateStart = CandidateAnchor(rect, screens: screens)
    }

    mutating func resetCandidateStart() {
        candidateStart = nil
        didCaptureCandidateStart = false
        candidateLineStartUTF16Offset = 0
    }

    mutating func updateCandidateLine(offset: Int, anchor: CandidateAnchor) {
        guard let current = candidateStart else { return }
        if offset != candidateLineStartUTF16Offset || !CandidateAnchor.sameLine(current.rect, anchor.rect) {
            candidateStart = anchor
            candidateLineStartUTF16Offset = offset
        }
    }

    mutating func shouldSend(_ text: String, selection: NSRange) -> Bool {
        guard self.selection != selection || self.text?.utf8.elementsEqual(text.utf8) != true else { return false }
        self.text = text
        self.selection = selection
        return true
    }

    mutating func reset(preservingCandidateStart: Bool = false) {
        text = nil
        selection = nil
        // Prefix confirmation gives the remainder a new inline coordinate space.
        candidateLineStartUTF16Offset = 0
        if !preservingCandidateStart { resetCandidateStart() }
    }
}
