#if SWIFT_PACKAGE
import SICore
#endif

/// A bounded newest-first page. The cursor is a database sequence, never an offset or timestamp.
public struct InputHistoryPage: Sendable {
    public let entries: [InputHistoryEntry]
    public let nextCursor: Int64?

    public init(entries: [InputHistoryEntry], nextCursor: Int64?) {
        self.entries = entries
        self.nextCursor = nextCursor
    }
}
