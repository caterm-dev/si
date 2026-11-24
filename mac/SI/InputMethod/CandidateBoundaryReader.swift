import Foundation

enum CandidateBoundaryReader {
    /// Only inspect the preceding edge of the host's current marked range, in UTF-16 units.
    /// Four units on the left allow a supplementary Han character plus a variation selector.
    static func read(markedText: String, cursorUTF16Offset: Int, isCurrent: () -> Bool,
                     selection: () -> NSRange, markedRange: () -> NSRange,
                     textWithActualRange: (NSRange) -> (text: String, range: NSRange)? = { _ in nil },
                     text: (NSRange) -> String?) -> String? {
        guard isCurrent() else { return nil }
        let count = markedText.utf16.count
        guard count > 0, cursorUTF16Offset >= 0, cursorUTF16Offset <= count else { return nil }
        let caret = selection()
        guard isCurrent() else { return nil }
        let reported = markedRange()
        guard isCurrent() else { return nil }
        let needsSpellingValidation = reported.location == NSNotFound || reported.length == 0
        let marked: NSRange
        if needsSpellingValidation {
            // Some clients expose the document caret but not markedRange. Derive a
            // possible range, then require an exact readback before using its edge.
            guard caret.location != NSNotFound, caret.location >= cursorUTF16Offset, caret.length == 0 else { return nil }
            marked = NSRange(location: caret.location - cursorUTF16Offset, length: count)
        } else {
            marked = reported
        }
        guard marked.location >= 0, marked.location != NSNotFound, marked.length == count,
              marked.location <= Int.max - marked.length,
              caret.location == NSNotFound || caret == NSRange(location: marked.location + cursorUTF16Offset, length: 0)
        else { return nil }
        func read(_ range: NSRange) -> String? {
            if range.length == 0 { return "" }
            guard isCurrent() else { return nil }
            if let value = text(range), isCurrent(), value.utf16.count == range.length { return value }
            guard isCurrent(), let response = textWithActualRange(range), isCurrent(),
                  response.range.location >= 0, response.range.location != NSNotFound,
                  response.range.location <= range.location,
                  response.range.length == response.text.utf16.count else { return nil }
            let offset = range.location - response.range.location
            guard offset <= response.range.length, range.length <= response.range.length - offset else { return nil }
            // Native clients may return a larger actual range. Keep only the requested
            // UTF-16 slice; a cut surrogate at the far left cannot affect its last character.
            return String(decoding: response.text.utf16.dropFirst(offset).prefix(range.length), as: UTF16.self)
        }
        if needsSpellingValidation {
            guard let inline = read(marked), isCurrent(), inline.utf8.elementsEqual(markedText.utf8) else { return nil }
        }
        let left = min(marked.location, 4)
        let before = read(NSRange(location: marked.location - left, length: left))
        guard isCurrent(), markedRange() == reported, isCurrent(), selection() == caret, isCurrent() else { return nil }
        return before
    }
}
