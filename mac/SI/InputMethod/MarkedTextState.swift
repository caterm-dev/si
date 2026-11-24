import Foundation

/// Last host update for one client/composition. Candidate deliveries resend marked
/// text only when its displayed spelling/segmentation or UTF-16 caret changes.
struct MarkedTextState {
    private(set) var text: String?
    private var selection: NSRange?
    var caretUTF16Offset: Int? { selection?.location }
    // Keep the original start through edits and prefix commits, even if later
    // host geometry follows the caret. Resolve its display again on use.
    var candidateStartRect: CGRect?

    func candidateAnchor(screens: [CandidatePlacement.Screen], queryStart: () -> CandidateAnchor?) -> CandidateAnchor? {
        candidateStartRect.flatMap { CandidateAnchor($0, screens: screens) } ?? queryStart()
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
        if !preservingCandidateStart { candidateStartRect = nil }
    }
}
