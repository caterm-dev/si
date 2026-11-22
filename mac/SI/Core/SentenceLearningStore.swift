import Foundation

/// Runs profile I/O and builds immutable decoder snapshots away from the main actor.
public actor SentenceLearningStore {
    public enum StoreError: Error { case profile }
    public typealias Snapshot = (model: SentenceLearningModel?, entries: [UserLexiconEntry])

    public static let maximumBatchSize = 32
    public static let maximumBatchBytes = 128 * 1_024

    private let profile: URL

    public init(profile: URL) {
        self.profile = profile
    }

    public func load() throws -> Snapshot {
        guard let base = RustConversion.shared else { throw StoreError.profile }
        let conversion = try base.loadUserModel(at: profile)
        return (conversion.map(SentenceLearningModel.init(conversion:)), conversion?.userEntries ?? [])
    }

    /// A batch ID makes retries safe even if ingestion succeeded but rebuilding the decoder failed.
    public func ingest(_ sentences: [String], batchID: UUID) throws -> Snapshot {
        guard let base = RustConversion.shared,
              (1...Self.maximumBatchSize).contains(sentences.count),
              sentences.allSatisfy({ (1...Self.maximumBatchBytes).contains($0.utf8.count) }),
              sentences.reduce(0, { $0 + $1.utf8.count }) <= Self.maximumBatchBytes else {
            throw StoreError.profile
        }
        try base.ingestUserSentences(sentences, batchID: batchID, at: profile)
        return try load()
    }

    public func edit(old: UserLexiconEntry?, new: UserLexiconEntry?) throws -> Snapshot {
        try RustConversion.editUserEntry(at: profile, old: old, new: new)
        return try load()
    }

    public func clear() throws {
        try RustConversion.clearUserModel(at: profile)
    }
}
