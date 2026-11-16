import Foundation
#if SWIFT_PACKAGE
import SICore
#endif

/// Reads the active text client's full value, revalidating after each host callback.
enum SentenceSnapshotReader {
    static func read(isCurrent: () -> Bool, selection: () -> NSRange, markedRange: () -> NSRange,
                     textLength: () -> Int, textInRange: (NSRange) -> String?,
                     textWithActualRange: (NSRange) -> (text: String, range: NSRange)?,
                     onFailure: (SentenceSnapshot.CaptureFailure) -> Void = { _ in }) -> String? {
        func fail(_ reason: SentenceSnapshot.CaptureFailure) -> String? {
            onFailure(reason)
            return nil
        }

        guard isCurrent() else { return fail(.staleClient) }
        let selected = selection()
        guard isCurrent() else { return fail(.staleClient) }
        let marked = markedRange()
        guard isCurrent() else { return fail(.staleClient) }
        guard marked.location == NSNotFound || marked.length == 0 else { return fail(.markedText) }

        let length = textLength()
        guard isCurrent() else { return fail(.staleClient) }
        let text: String
        if length == NSNotFound {
            switch readWithoutLength(isCurrent: isCurrent, textWithActualRange: textWithActualRange) {
            case .success(let value): text = value
            case .failure(let reason): return fail(reason)
            }
        } else {
            guard length > 0 else { return fail(.invalidText) }
            let snapshot = textInRange(NSRange(location: 0, length: length))
            guard isCurrent() else { return fail(.staleClient) }
            guard let snapshot else { return fail(.unavailableText) }
            guard snapshot.utf16.count == length else { return fail(.incompleteRange) }
            text = snapshot
        }

        guard SentenceSnapshot.accepts(text) else { return fail(.invalidText) }
        if selected.location != NSNotFound {
            let (end, overflow) = selected.location.addingReportingOverflow(selected.length)
            guard !overflow, selected.location >= 0, selected.length >= 0, end <= text.utf16.count else {
                return fail(.incompleteRange)
            }
        }
        guard selection() == selected, isCurrent(), markedRange() == marked, isCurrent(),
              textLength() == length, isCurrent() else { return fail(.staleClient) }
        return text
    }

    private static func readWithoutLength(
        isCurrent: () -> Bool, textWithActualRange: (NSRange) -> (text: String, range: NSRange)?
    ) -> Result<String, SentenceSnapshot.CaptureFailure> {
        var requested = 4_096
        // Some hosts report their actual range only when a proposed range reaches the field's end.
        while requested <= Int.max / 2 {
            let snapshot = textWithActualRange(NSRange(location: 0, length: requested))
            guard isCurrent() else { return .failure(.staleClient) }
            guard let snapshot else { return .failure(.unavailableText) }
            guard snapshot.range.location == 0, (0...(requested + 1)).contains(snapshot.range.length),
                  snapshot.text.utf16.count == snapshot.range.length else { return .failure(.incompleteRange) }
            // A host may shorten or extend by one UTF-16 unit to avoid splitting a surrogate pair.
            if snapshot.range.length < requested - 1 { return .success(snapshot.text) }
            requested *= 2
        }
        return .failure(.incompleteRange)
    }
}
