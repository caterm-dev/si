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

    static func startIndices(marked: NSRange) -> [Int] {
        // IMK's geometry index is inline-relative. Keep the document-relative start
        // as a compatibility probe for hosts that interpret the index that way.
        let start = marked.location
        guard start > 0, start != NSNotFound,
              marked.length > 0, marked.length <= Int.max - start else { return [0] }
        return [0, start]
    }

    static func fallback(lastValid: CGRect?, mouseLocation: @autoclosure () -> CGPoint,
                         screens: [CandidatePlacement.Screen]) -> CandidateAnchor? {
        if let lastValid, let anchor = CandidateAnchor(lastValid, screens: screens) { return anchor }
        let rect = CGRect(origin: mouseLocation(), size: CGSize(width: 1, height: 1))
        return CandidateAnchor(rect, screens: screens)
    }
}
