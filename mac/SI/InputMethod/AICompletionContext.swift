import Foundation

struct AICompletionField: Equatable, Encodable, Sendable {
    struct Position: Equatable, Sendable {
        let marked: NSRange
        let selection: NSRange
    }

    let before: String
    let after: String
    let markedRange: NSRange
    let selection: NSRange

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.markedRange == rhs.markedRange && lhs.selection == rhs.selection
            && lhs.before.utf8.elementsEqual(rhs.before.utf8) && lhs.after.utf8.elementsEqual(rhs.after.utf8)
    }

    /// Keep the host's spelling decoration separate from the exact SI composition.
    static func read(markedText: String, cursorUTF16Offset: Int, isCurrent: () -> Bool,
                     selection: () -> NSRange, markedRange: () -> NSRange, length: () -> Int,
                     text: (NSRange) -> String?, isolation: isolated (any Actor)? = #isolation) -> Self? {
        guard isCurrent() else { return nil }
        let marked = markedRange()
        guard isCurrent(), marked.location != NSNotFound, marked.location >= 0,
              marked.length == markedText.utf16.count, marked.length > 0,
              marked.location <= Int.max - marked.length else { return nil }
        let caret = selection()
        guard isCurrent(), cursorUTF16Offset >= 0, cursorUTF16Offset <= marked.length,
              caret == NSRange(location: marked.location + cursorUTF16Offset, length: 0) else { return nil }
        let fieldLength = length()
        let end = NSMaxRange(marked)
        guard isCurrent(), fieldLength >= end,
              let inline = text(marked), inline.utf8.elementsEqual(markedText.utf8), isCurrent() else { return nil }
        func read(_ range: NSRange) -> String? {
            if range.length == 0 { return "" }
            guard let value = text(range), value.utf16.count == range.length else { return nil }
            return value
        }
        let left = min(marked.location, 1024)
        let right = min(fieldLength - end, 1024)
        guard let before = read(NSRange(location: marked.location - left, length: left)), isCurrent(),
              let after = read(NSRange(location: end, length: right)), isCurrent(),
              markedRange() == marked, isCurrent(), selection() == caret, isCurrent() else { return nil }
        return Self(before: before, after: after, markedRange: marked, selection: caret)
    }
}

struct AICompletionContext: Encodable, Sendable {
    let currentInput: String
    let candidate: String
    let fieldBefore: String?
    let fieldAfter: String?
}
