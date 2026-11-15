import Foundation

enum PrecedingTextReader {
    /// Read the complete committed prefix before starting or replacing marked text.
    static func read(isCurrent: () -> Bool, selection: () -> NSRange, markedRange: () -> NSRange,
                     text: (NSRange) -> String?) -> String? {
        guard isCurrent() else { return nil }
        let selected = selection()
        guard isCurrent(), selected.location > 0, selected.location != NSNotFound, selected.length >= 0,
              selected.length <= Int.max - selected.location else { return nil }
        let marked = markedRange()
        guard isCurrent(), marked.location == NSNotFound || marked.length == 0 else { return nil }
        let range = NSRange(location: 0, length: selected.location)
        guard var prefix = text(range), isCurrent(), prefix.utf16.count == range.length,
              selection() == selected, isCurrent(), markedRange() == marked, isCurrent() else { return nil }
        prefix.makeContiguousUTF8()
        return prefix
    }
}
