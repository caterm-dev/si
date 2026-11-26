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

    static func documentRange(inlineOffset: Int, inlineUTF16Count: Int, marked: NSRange) -> NSRange? {
        guard marked.location >= 0, marked.location != NSNotFound,
              marked.length == inlineUTF16Count, marked.length >= 0,
              marked.location <= Int.max - marked.length,
              inlineOffset >= 0, inlineOffset <= marked.length else { return nil }
        return NSRange(location: marked.location + inlineOffset, length: 0)
    }

    static func acceptsDocumentGeometry(actual: NSRange, requested: NSRange, marked: NSRange) -> Bool {
        guard actual.location == requested.location, actual.location != NSNotFound,
              actual.length >= 0, marked.location >= 0, marked.location != NSNotFound,
              requested.location >= marked.location else { return false }
        let offset = requested.location - marked.location
        return offset <= marked.length && actual.length <= marked.length - offset
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
        var unavailable = Set<Int>()
        var remainingProbes = 32
        func read(_ index: Int) -> CandidateAnchor? {
            if let cached = anchors[index] { return cached }
            guard !unavailable.contains(index), remainingProbes > 0 else { return nil }
            remainingProbes -= 1
            guard !stopped, let rect = rectangleAt(index) else { stopped = true; return nil }
            let anchor = CandidateAnchor(rect, screens: screens)
            anchors[index] = anchor
            if anchor == nil { unavailable.insert(index) }
            return anchor
        }
        var end = boundaries.count - 1
        var caret: CandidateAnchor?
        // Some clients expose geometry for only occasional inline characters.
        // Search a bounded tail instead of giving up after one missing character.
        for _ in 0..<8 {
            caret = read(boundaries[end])
            if caret != nil || stopped || end == 0 { break }
            end -= 1
        }
        guard let caret, !stopped else { return nil }

        let leftToRightSpelling = inlineText.unicodeScalars.allSatisfy {
            $0.isASCII || $0 == "ü" || $0 == "Ü"
        }
        func precedesCaretOnSameLine(_ earlier: CandidateAnchor) -> Bool {
            // A bottom-aligned composer can move its lines as text wraps. Old
            // and new line rectangles may then overlap in screen coordinates.
            sameLine(earlier.rect, caret.rect)
                && (!leftToRightSpelling || earlier.rect.minX <= caret.rect.maxX)
        }

        var lower = 0
        if retainedStart > 0, let first = read(0), precedesCaretOnSameLine(first) { return (0, first) }
        guard !stopped else { return nil }
        // Most edits stay on the same line: probe its retained source position once.
        if let retainedPosition = boundaries.firstIndex(of: retainedStart), retainedPosition <= end {
            let retained = read(retainedStart)
            guard !stopped else { return nil }
            if let retained {
                if precedesCaretOnSameLine(retained) { return (retainedStart, retained) }
                // Only an earlier source position whose geometry actually precedes
                // the caret can narrow the search. A later line may instead follow
                // the caret when deletion or Home moves back to an earlier line.
                if retainedPosition == 0 { lower = 1 }
            }
        }

        // Search for the earliest character on the caret's line. When the host
        // returns sparse geometry, keep the earliest rectangle verified so far.
        var upper = end
        var start = caret
        for _ in 0..<32 {
            if lower == upper { break }
            let middle = lower + (upper - lower) / 2
            var position = middle
            var probe = read(boundaries[position])
            if probe == nil, !stopped, middle > lower {
                position = middle - 1
                probe = read(boundaries[position])
            }
            if probe == nil, !stopped, middle + 1 < upper {
                position = middle + 1
                probe = read(boundaries[position])
            }
            guard !stopped else { return nil }
            if let probe, precedesCaretOnSameLine(probe) {
                upper = position
                start = probe
            } else if probe != nil {
                lower = position + 1
            } else {
                lower = middle + 1
            }
        }
        return (boundaries[upper], start)
    }
}
