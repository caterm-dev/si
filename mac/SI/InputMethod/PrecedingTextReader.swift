import Foundation
#if SWIFT_PACKAGE
import SICore
#endif

enum PrecedingTextReader {
    /// Read a bounded committed suffix without interpreting or rewriting its text.
    static func read(isCurrent: () -> Bool, selection: () -> NSRange, markedRange: () -> NSRange,
                     utf16Limit: Int = CandidateEngine.precedingTextUTF16Limit,
                     text: (NSRange) -> String?) -> String? {
        guard isCurrent(), utf16Limit > 0 else { return nil }
        let selected = selection()
        guard isCurrent(), selected.location >= 0, selected.location != NSNotFound, selected.length >= 0,
              selected.length <= Int.max - selected.location else { return nil }
        let marked = markedRange()
        guard isCurrent(), marked.location == NSNotFound || marked.length == 0 else { return nil }
        if selected.location == 0 {
            guard selection() == selected, isCurrent(), markedRange() == marked, isCurrent() else { return nil }
            return ""
        }
        let length = min(selected.location, utf16Limit)
        let range = NSRange(location: selected.location - length, length: length)
        guard var prefix = text(range), isCurrent(), prefix.utf16.count == range.length,
              selection() == selected, isCurrent(), markedRange() == marked, isCurrent() else { return nil }
        prefix.makeContiguousUTF8()
        return prefix
    }
}
