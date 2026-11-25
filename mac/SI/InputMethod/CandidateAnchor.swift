import Foundation
import CoreGraphics

struct CandidateAnchor {
    let rect: CGRect
    let screen: CandidatePlacement.Screen

    init?(_ rawRect: CGRect, screens: [CandidatePlacement.Screen]) {
        guard let rect = CandidatePlacement.normalizedAnchor(rawRect),
              let screen = CandidatePlacement.screen(for: rect, screens: screens) else { return nil }
        self.rect = rect
        self.screen = screen
    }

    static func sameLine(_ first: CGRect, _ second: CGRect) -> Bool {
        min(first.maxY, second.maxY) - max(first.minY, second.minY) > min(first.height, second.height) / 2
    }

    /// Resolve the active visual line from host geometry, without following its caret horizontally.
    /// Nil rectangles stop obsolete queries; unusable geometry keeps the previous anchor.
    static func activeLine(inlineText: String, caretUTF16Offset: Int, retainedStart: Int,
                           screens: [CandidatePlacement.Screen], rectangleAt: (Int) -> CGRect?)
        -> (offset: Int, anchor: CandidateAnchor)? {
        var boundaries = [0]
        var offset = 0
        for character in inlineText {
            offset += character.utf16.count
            if offset > caretUTF16Offset { break }
            boundaries.append(offset)
        }
        guard !inlineText.isEmpty, caretUTF16Offset >= 0,
              caretUTF16Offset <= inlineText.utf16.count,
              boundaries.last == caretUTF16Offset else { return nil }
        var stopped = false
        var anchors: [Int: CandidateAnchor] = [:]
        func read(_ index: Int) -> CandidateAnchor? {
            if let cached = anchors[index] { return cached }
            guard !stopped, let rect = rectangleAt(index) else { stopped = true; return nil }
            let anchor = CandidateAnchor(rect, screens: screens)
            anchors[index] = anchor
            return anchor
        }
        var end = boundaries.count - 1
        var caret = read(boundaries[end])
        if caret == nil, !stopped, end > 0 {
            end -= 1
            caret = read(boundaries[end])
        }
        guard let caret, !stopped else { return nil }

        // Most edits stay on the same line: probe its retained source position once.
        if retainedStart <= boundaries[end], boundaries.contains(retainedStart) {
            guard let retained = read(retainedStart) else { return nil }
            if sameLine(retained.rect, caret.rect) { return (retainedStart, retained) }
        }

        // All indices precede the caret. Their line membership is monotonic, so a
        // bounded binary search finds the first character on the active line.
        var lower = 0
        var upper = end
        for _ in 0..<32 {
            if lower == upper { break }
            let middle = lower + (upper - lower) / 2
            guard let probe = read(boundaries[middle]) else { return nil }
            if sameLine(probe.rect, caret.rect) { upper = middle }
            else { lower = middle + 1 }
        }
        guard lower == upper, let start = read(boundaries[lower]) else { return nil }
        return (boundaries[lower], start)
    }
}
