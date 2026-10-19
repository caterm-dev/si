import Foundation
import CoreGraphics

// Geometry only, scoped to one composition/client. No surrounding document text is read.
struct CandidateAnchor {
    private var lastValid: CGRect?

    mutating func reset() { lastValid = nil }

    mutating func resolve(cursorUTF16Offset: Int, screens: [CandidatePlacement.Screen],
                          query: (Int) -> CGRect) -> CGRect? {
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
