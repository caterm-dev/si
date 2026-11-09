import Foundation
#if SWIFT_PACKAGE
import SICore
#endif

/// Read available single-line text before the caret, checking eligibility between synchronous host callbacks.
enum SentenceSnapshotReader {
    static func read(isCurrent: () -> Bool, selection: () -> NSRange, markedRange: () -> NSRange,
                     textInRange: (NSRange) -> String?,
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
        let text = textInRange(range)
        guard isCurrent() else { return fail(.staleClient) }
        guard let text else { return fail(.unavailableText) }
        guard SentenceSnapshot.accepts(text) else { return fail(.invalidText) }
        guard selection() == caret, isCurrent() else { return fail(.staleClient) }
        return text
    }
}
