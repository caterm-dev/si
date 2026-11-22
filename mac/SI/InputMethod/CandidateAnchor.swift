import Foundation

struct CandidateAnchor {
    let rect: CGRect
    let screen: CandidatePlacement.Screen

    init?(_ rawRect: CGRect, screens: [CandidatePlacement.Screen]) {
        guard let rect = CandidatePlacement.normalizedAnchor(rawRect),
              let screen = CandidatePlacement.screen(for: rect, screens: screens) else { return nil }
        self.rect = rect
        self.screen = screen
    }

    static func queryIndices(inlineText: String, caretUTF16Offset: Int, marked: NSRange, selected: NSRange) -> [Int] {
        var indices: [Int] = []
        func append(_ index: Int) {
            if index >= 0, index != NSNotFound, !indices.contains(index) { indices.append(index) }
        }
        // IMK's geometry API takes an offset into the current inline composition.
        // Some clients only return a rectangle for an existing character at the end.
        append(caretUTF16Offset)
        if caretUTF16Offset == inlineText.utf16.count, let last = inlineText.last {
            let lastCharacterStart = caretUTF16Offset - last.utf16.count
            if lastCharacterStart > 0 { append(lastCharacterStart) }
        }

        // Keep the document ranges as compatibility probes for clients that accept them.
        if marked.location >= 0, marked.location != NSNotFound {
            append(marked.location)
            let (end, overflow) = marked.location.addingReportingOverflow(marked.length)
            if marked.length >= 0, !overflow { append(end) }
        }
        append(selected.location)
        append(0)
        return indices
    }

    static func fallback(lastValid: CGRect?, mouseLocation: @autoclosure () -> CGPoint,
                         screens: [CandidatePlacement.Screen]) -> CandidateAnchor? {
        if let lastValid, let anchor = CandidateAnchor(lastValid, screens: screens) { return anchor }
        let rect = CGRect(origin: mouseLocation(), size: CGSize(width: 1, height: 1))
        return CandidateAnchor(rect, screens: screens)
    }
}
