import Foundation

enum CandidateBoundaryReader {
    /// Only inspect the preceding edge of the host's current marked range, in UTF-16 units.
    /// Four units on the left allow a supplementary Han character plus a variation selector.
    static func read(markedText: String, cursorUTF16Offset: Int, isCurrent: () -> Bool,
                     selection: () -> NSRange, markedRange: () -> NSRange,
                     text: (NSRange) -> String?) -> String? {
        guard isCurrent() else { return nil }
        let marked = markedRange()
        guard isCurrent(), marked.location != NSNotFound, marked.location >= 0,
              marked.length > 0, marked.length == markedText.utf16.count,
              marked.location <= Int.max - marked.length,
              cursorUTF16Offset >= 0, cursorUTF16Offset <= marked.length else { return nil }
        let caret = selection()
        guard isCurrent(), caret == NSRange(location: marked.location + cursorUTF16Offset, length: 0),
              let inline = text(marked), isCurrent(), inline.utf8.elementsEqual(markedText.utf8) else { return nil }
        func read(_ range: NSRange) -> String? {
            if range.length == 0 { return "" }
            guard let value = text(range), value.utf16.count == range.length else { return nil }
            return value
        }
        let left = min(marked.location, 4)
        let before = read(NSRange(location: marked.location - left, length: left))
        guard isCurrent(), markedRange() == marked, isCurrent(), selection() == caret, isCurrent() else { return nil }
        return before
    }
}
