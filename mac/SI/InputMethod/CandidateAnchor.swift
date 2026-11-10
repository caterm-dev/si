import Foundation
import CoreGraphics

// Geometry only, scoped to one composition/client. No surrounding document text is read.
struct CandidateAnchor {
    private var lastValid: CGRect?
    private var lastDocument: CGRect?

    mutating func reset() {
        lastValid = nil
        lastDocument = nil
    }

    mutating func resolve(cursorUTF16Offset: Int, markedRange: NSRange = NSRange(location: NSNotFound, length: 0),
                          screens: [CandidatePlacement.Screen], queryRange: (NSRange) -> CGRect = { _ in .zero },
                          isInMarkedRange: (CGRect) -> Bool? = { _ in nil },
                          query: (Int) -> CGRect) -> CGRect? {
        if let lastValid, CandidatePlacement.screen(for: lastValid, screens: screens) == nil { reset() }
        // Prefer inline geometry, but being on screen does not establish that a host's
        // rectangle still belongs to this composition. A point lookup can corroborate it.
        var originCaret: CGRect?
        var inlineCaret: CGRect?
        var indexes = [0]
        if cursorUTF16Offset > 0 { indexes.append(cursorUTF16Offset) }
        for index in indexes {
            guard let rect = CandidatePlacement.normalizedAnchor(query(index)),
                  CandidatePlacement.screen(for: rect, screens: screens) != nil else { continue }
            // An uncorroborated origin is ambiguous: some hosts report a default line
            // rectangle there while layout is pending. Do not flash a panel at (0,0).
            if rect.origin == .zero { originCaret = rect; continue }
            let matches = isInMarkedRange(rect)
            if matches == true { lastValid = rect; return rect }
            if matches == nil { inlineCaret = rect; break }
        }
        // Always try fresh document geometry before a cache. Otherwise a transient
        // inline failure can pin the panel to its old location after host reflow.
        // The caller also validates the returned document range.
        if markedRange.location >= 0, markedRange.location != NSNotFound,
           markedRange.length > 0, markedRange.length != NSNotFound,
           markedRange.length <= Int.max - markedRange.location,
           let rect = CandidatePlacement.normalizedAnchor(queryRange(NSRange(location: markedRange.location, length: 0))),
           CandidatePlacement.screen(for: rect, screens: screens) != nil {
            let previousDocument = lastDocument
            lastDocument = rect
            if rect.origin != .zero || originCaret == rect {
                let matches = rect == inlineCaret ? nil : isInMarkedRange(rect)
                // A repeated uncorroborated fallback that previously lost to inline
                // geometry is not evidence of reflow. Keep the established position.
                let isFresh = rect != previousDocument || lastValid == nil
                if matches != false, matches == true || (inlineCaret == nil && isFresh) {
                    lastValid = rect
                    return rect
                }
            }
        }
        if let inlineCaret { lastValid = inlineCaret; return inlineCaret }
        // Unknown point lookup support preserves the composition-local fallback;
        // an explicit mismatch must not keep a known displaced position alive.
        if let lastValid, isInMarkedRange(lastValid) == false { self.lastValid = nil }
        return lastValid
    }

    static func documentRect(_ rect: CGRect, actualRange: NSRange, requestedRange: NSRange) -> CGRect {
        guard requestedRange.location >= 0, requestedRange.location != NSNotFound, requestedRange.length == 0,
              actualRange.location >= 0, actualRange.location != NSNotFound,
              actualRange.length >= 0, actualRange.length != NSNotFound,
              actualRange.length <= Int.max - actualRange.location,
              requestedRange.location >= actualRange.location,
              requestedRange.location <= actualRange.location + actualRange.length else { return .null }
        return rect
    }
}
