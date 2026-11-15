import Foundation

/// Runs profile I/O and builds immutable decoder snapshots away from the main actor.
public actor SentenceLearningStore {
    public enum StoreError: Error { case profile }

    private let profile: URL

    public init(profile: URL) {
        self.profile = profile
    }

    public func load() throws -> SentenceLearningModel? {
        guard let base = RustConversion.shared else { throw StoreError.profile }
        return try base.loadUserModel(at: profile).map(SentenceLearningModel.init(conversion:))
    }

    /// A batch ID makes retries safe even if ingestion succeeded but rebuilding the decoder failed.
    public func ingest(_ sentences: [String], batchID: UUID) throws -> SentenceLearningModel? {
        guard let base = RustConversion.shared,
              !sentences.isEmpty, sentences.count <= 32, sentences.allSatisfy(SentenceSnapshot.accepts) else {
            throw StoreError.profile
        }
        try base.ingestUserSentences(sentences, batchID: batchID, at: profile)
        return try load()
    }

    public func clear() throws {
        try RustConversion.clearUserModel(at: profile)
    }
}
