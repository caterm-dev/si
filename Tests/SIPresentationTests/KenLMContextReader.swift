import Foundation
#if SWIFT_PACKAGE
import SICore
#endif

/// Only the prefix before SI's marked range (or an unmarked insertion caret).
/// Revalidate after every host callback; unknown/partial ranges yield no context.
enum KenLMContextReader {
    static func read(markedText: String?, isCurrent: () -> Bool,
                     selection: () -> NSRange, markedRange: () -> NSRange,
                     text: (NSRange) -> String?, isolation: isolated (any Actor)? = #isolation) -> KenLMContext? {
        guard isCurrent() else { return nil }
        let caret = selection()
        guard isCurrent(), caret.location != NSNotFound, caret.location >= 0, caret.length == 0 else { return nil }
        let marked = markedRange()
        guard isCurrent() else { return nil }
        let hasMarked = marked.location != NSNotFound && marked.length > 0
        let start: Int
        if hasMarked {
            guard let markedText, marked.location >= 0, marked.length == markedText.utf16.count,
                  marked.location <= Int.max - marked.length,
                  caret.location >= marked.location, caret.location <= NSMaxRange(marked) else { return nil }
            start = marked.location
        } else {
            guard marked.length == 0 else { return nil }
            start = caret.location
        }
        // No document-length query: the SDK warns it can scan the whole document.
        // Verified caret/marked ranges plus an exact-length substring suffice here.
        if hasMarked {
            guard let inline = text(marked), isCurrent(),
                  inline.utf8.elementsEqual(markedText!.utf8) else { return nil }
        }
        let count = min(start, KenLMContext.maximumUTF16Length)
        let range = NSRange(location: start - count, length: count)
        let before: String
        if count == 0 { before = "" }
        else {
            guard let value = text(range), isCurrent(), value.utf16.count == count,
                  !value.unicodeScalars.contains("\u{fffd}") else { return nil }
            before = value
        }
        guard markedRange() == marked, isCurrent(), selection() == caret, isCurrent() else { return nil }
        return KenLMContext(text: before, isTruncated: range.location > 0)
    }
}
