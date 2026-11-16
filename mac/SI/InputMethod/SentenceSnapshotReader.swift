import Foundation
#if SWIFT_PACKAGE
import SICore
#endif

/// Reads the active text client's full value when available.
enum SentenceSnapshotReader {
    struct Capture {
        let text: String
        let coverage: SentenceSnapshot.Coverage
    }

    static func read(isCurrent: () -> Bool, selection: () -> NSRange, markedRange: () -> NSRange,
                     textLength: () -> Int, textInRange: (NSRange) -> String?,
                     textWithActualRange: (NSRange) -> (text: String, range: NSRange)?,
                     onFailure: (SentenceSnapshot.CaptureFailure) -> Void = { _ in }) -> Capture? {
        func fail(_ reason: SentenceSnapshot.CaptureFailure) -> Capture? {
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
        let fullRead: Result<String, SentenceSnapshot.CaptureFailure>
        if length <= 0 || length == NSNotFound {
            // A zero length can also mean that the host did not supply a length.
            fullRead = readWithoutLength(isCurrent: isCurrent, textWithActualRange: textWithActualRange)
        } else {
            let snapshot = textInRange(NSRange(location: 0, length: length))
            guard isCurrent() else { return fail(.staleClient) }
            if let snapshot {
                fullRead = snapshot.utf16.count == length ? .success(snapshot) : .failure(.incompleteRange)
            } else {
                fullRead = .failure(.unavailableText)
            }
        }

        let capture: Capture
        switch fullRead {
        case .success(let text) where selectionFits(selected, length: text.utf16.count):
            capture = Capture(text: text, coverage: .fullField)
        case .failure(.staleClient):
            return fail(.staleClient)
        case .success, .failure:
            // The former Sentence History could read this range even when the full field was unavailable.
            guard selected.location > 0, selected.location != NSNotFound else {
                if case .failure(let reason) = fullRead { return fail(reason) }
                return fail(.incompleteRange)
            }
            let prefix = textInRange(NSRange(location: 0, length: selected.location))
            guard isCurrent() else { return fail(.staleClient) }
            guard let prefix else { return fail(.unavailableText) }
            guard prefix.utf16.count == selected.location else { return fail(.incompleteRange) }
            capture = Capture(text: prefix, coverage: .beforeCaret)
        }

        guard selection() == selected, isCurrent(), markedRange() == marked, isCurrent(),
              textLength() == length, isCurrent() else { return fail(.staleClient) }
        guard SentenceSnapshot.accepts(capture.text) else { return fail(.invalidText) }
        return capture
    }

    private static func selectionFits(_ selected: NSRange, length: Int) -> Bool {
        if selected.location == NSNotFound { return true }
        let (end, overflow) = selected.location.addingReportingOverflow(selected.length)
        return !overflow && selected.location >= 0 && selected.length >= 0 && end <= length
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
