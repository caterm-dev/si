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

    static func queryIndices(marked: NSRange, selected: NSRange) -> [Int] {
        var indices: [Int] = []
        func append(_ index: Int) {
            if index >= 0, index != NSNotFound, !indices.contains(index) { indices.append(index) }
        }
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
