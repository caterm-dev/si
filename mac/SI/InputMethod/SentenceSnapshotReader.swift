import Foundation
#if SWIFT_PACKAGE
import SICore
#endif

/// Read a complete short line, checking eligibility between synchronous host callbacks.
enum SentenceSnapshotReader {
    static func read(isCurrent: () -> Bool, selection: () -> NSRange, markedRange: () -> NSRange,
                     length: () -> Int, textInRange: (NSRange) -> String?) -> String? {
        guard isCurrent() else { return nil }
        let caret = selection()
        guard let range = SentenceSnapshot.range(endingAt: caret), isCurrent() else { return nil }
        let marked = markedRange()
        guard (marked.location == NSNotFound || marked.length == 0), isCurrent(),
              length() == range.length, isCurrent(),
              let text = textInRange(range), text.utf16.count == range.length, SentenceSnapshot.accepts(text),
              isCurrent(), selection() == caret, isCurrent() else { return nil }
        return text
    }
}
