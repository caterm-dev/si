import Foundation

/// Runs profile I/O and builds immutable decoder snapshots away from the main actor.
public actor SentenceLearningStore {
    public enum StoreError: Error { case profile }
    public typealias Snapshot = (model: SentenceLearningModel?, recentSamples: [String], entries: [UserLexiconEntry])

    private let profile: URL

    public init(profile: URL) {
        self.profile = profile
    }

    public func load() throws -> Snapshot {
        guard let base = RustConversion.shared else { throw StoreError.profile }
        let snapshot = try base.loadUserModel(at: profile)
        return (snapshot.conversion.map(SentenceLearningModel.init(conversion:)), snapshot.recentSamples, snapshot.conversion?.userEntries ?? [])
    }

    /// A batch ID makes retries safe even if ingestion succeeded but rebuilding the decoder failed.
    public func ingest(_ sentences: [String], batchID: UUID) throws -> Snapshot {
        guard let base = RustConversion.shared,
              !sentences.isEmpty, sentences.count <= 32, sentences.allSatisfy(SentenceSnapshot.accepts) else {
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
