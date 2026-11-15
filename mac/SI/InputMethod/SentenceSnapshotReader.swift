import Foundation
#if SWIFT_PACKAGE
import SICore
#endif

/// Read a bounded single-line client value at the end of the text, revalidating after each host callback.
enum SentenceSnapshotReader {
    static func read(isCurrent: () -> Bool, selection: () -> NSRange, markedRange: () -> NSRange,
                     textLength: () -> Int, textInRange: (NSRange) -> String?,
                     onFailure: (SentenceSnapshot.CaptureFailure) -> Void = { _ in }) -> String? {
        func fail(_ reason: SentenceSnapshot.CaptureFailure) -> String? {
            onFailure(reason)
            return nil
        }
        guard isCurrent() else { return fail(.staleClient) }
        let caret = selection()
        guard isCurrent() else { return fail(.staleClient) }
        guard caret.location != NSNotFound else { return fail(.unavailableSelection) }
        guard let range = SentenceSnapshot.range(endingAt: caret) else { return fail(.invalidSelection) }
        let marked = markedRange()
        guard isCurrent() else { return fail(.staleClient) }
        guard marked.location == NSNotFound || marked.length == 0 else { return fail(.markedText) }
        let length = textLength()
        guard isCurrent() else { return fail(.staleClient) }
        guard length == range.length else { return fail(.incompleteRange) }
        let text = textInRange(range)
        guard isCurrent() else { return fail(.staleClient) }
        guard let text else { return fail(.unavailableText) }
        guard SentenceSnapshot.accepts(text) else { return fail(.invalidText) }
        guard text.utf16.count == length else { return fail(.incompleteRange) }
        guard selection() == caret, isCurrent() else { return fail(.staleClient) }
        guard textLength() == length, isCurrent() else { return fail(.staleClient) }
        return text
    }
}
