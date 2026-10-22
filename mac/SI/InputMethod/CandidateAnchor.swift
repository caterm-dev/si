import Foundation
import CoreGraphics

// Geometry only, scoped to one composition/client. No surrounding document text is read.
struct CandidateAnchor {
    private var lastValid: CGRect?
    private var hasInlineAnchor = false

    mutating func reset() {
        lastValid = nil
        hasInlineAnchor = false
    }

    mutating func resolve(cursorUTF16Offset: Int, markedRange: NSRange = NSRange(location: NSNotFound, length: 0),
                          screens: [CandidatePlacement.Screen], queryRange: (NSRange) -> CGRect = { _ in .zero },
                          query: (Int) -> CGRect) -> CGRect? {
        if let lastValid, CandidatePlacement.screen(for: lastValid, screens: screens) == nil { reset() }
        // IMK's inline-session API is specifically provided for positioning candidate
        // windows. A document-access rectangle must not override a fresh inline caret.
        var originCaret: CGRect?
        var indexes = [0]
        if cursorUTF16Offset > 0 { indexes.append(cursorUTF16Offset) }
        for index in indexes {
            guard let rect = CandidatePlacement.normalizedAnchor(query(index)),
                  CandidatePlacement.screen(for: rect, screens: screens) != nil else { continue }
            // An uncorroborated origin is ambiguous: some hosts report a default line
            // rectangle there while layout is pending. Do not flash a panel at (0,0).
            if rect.origin == .zero { originCaret = rect; continue }
            lastValid = rect
            hasInlineAnchor = true
            return rect
        }
        let cachedInline = hasInlineAnchor ? lastValid : nil
        if originCaret == nil, let cachedInline { return cachedInline }
        // Document access is only a fallback; the caller validates its returned range.
        if markedRange.location >= 0, markedRange.location != NSNotFound,
           markedRange.length > 0, markedRange.length != NSNotFound,
           markedRange.length <= Int.max - markedRange.location,
           let rect = CandidatePlacement.normalizedAnchor(queryRange(NSRange(location: markedRange.location, length: 0))),
           CandidatePlacement.screen(for: rect, screens: screens) != nil {
            if rect.origin == .zero && originCaret == nil { return lastValid }
            if rect.origin != .zero, let cachedInline { return cachedInline }
            lastValid = rect
            return rect
        }
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
