import Foundation
import CoreGraphics

// Geometry only, scoped to one composition/client. No surrounding document text is read.
struct CandidateAnchor {
    private var lastValid: CGRect?

    mutating func reset() { lastValid = nil }

    mutating func resolve(cursorUTF16Offset: Int, markedRange: NSRange = NSRange(location: NSNotFound, length: 0),
                          screens: [CandidatePlacement.Screen], queryRange: (NSRange) -> CGRect = { _ in .zero },
                          query: (Int) -> CGRect) -> CGRect? {
        // Ask for an insertion rectangle at the document-relative marked start. Some hosts
        // return displaced geometry through the legacy inline-relative attributes query.
        if markedRange.location >= 0, markedRange.location != NSNotFound,
           markedRange.length > 0, markedRange.length != NSNotFound,
           markedRange.length <= Int.max - markedRange.location,
           let rect = CandidatePlacement.normalizedAnchor(queryRange(NSRange(location: markedRange.location, length: 0))),
           CandidatePlacement.screen(for: rect, screens: screens) != nil {
            lastValid = rect
            return rect
        }
        // The composition's first glyph is stable; end-of-marked-text queries may be unavailable.
        var indexes = [0]
        if cursorUTF16Offset > 0 { indexes.append(cursorUTF16Offset) }
        for index in indexes {
            guard let rect = CandidatePlacement.normalizedAnchor(query(index)),
                  CandidatePlacement.screen(for: rect, screens: screens) != nil else { continue }
            lastValid = rect
            return rect
        }
        guard let lastValid, CandidatePlacement.screen(for: lastValid, screens: screens) != nil else {
            self.lastValid = nil
            return nil
        }
        return lastValid
    }
}
