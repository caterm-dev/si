import Foundation
#if SWIFT_PACKAGE
import SICore
#endif

public actor ApplicationMemoryStore {
    public enum StoreError: Error { case unsupportedVersion }
    private struct Archive: Codable {
        let version: Int
        let vocabulary: [ApplicationVocabularyEntry]
        let history: [ApplicationHistoryEntry]
    }

    public static let maximumFileBytes = 64 * 1_024 * 1_024
    private let url: URL
    private let legacyLearningURL: URL?
    private var lastRevision = -1

    public init(url: URL, legacyLearningURL: URL? = nil) {
        self.url = url
        self.legacyLearningURL = legacyLearningURL
    }

    /// Detect/delete retired shared data without decoding or using its contents.
    public func hasLegacyLearningData() -> Bool {
        legacyLearningURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    public func eraseLegacyLearningData() throws {
        if let legacyLearningURL { try PrivateArchiveFile.erase(legacyLearningURL) }
    }

    public func load(now: Date = .now) throws -> ApplicationMemory {
        guard let data = try PrivateArchiveFile.read(url, maximumBytes: Self.maximumFileBytes) else { return ApplicationMemory() }
        let archive = try JSONDecoder().decode(Archive.self, from: data)
        guard archive.version == 1 else { throw StoreError.unsupportedVersion }
        let memory = ApplicationMemory(vocabulary: archive.vocabulary, history: archive.history, now: now)
        if memory.vocabulary != archive.vocabulary || memory.history != archive.history { try write(memory) }
        return memory
    }

    public func save(_ memory: ApplicationMemory, revision: Int) throws {
        guard revision > lastRevision else { return }
        try write(memory)
        lastRevision = revision
    }

    public func erase(revision: Int) throws {
        guard revision > lastRevision else { return }
        try PrivateArchiveFile.erase(url)
        lastRevision = revision
    }

    private func write(_ memory: ApplicationMemory) throws {
        let data = try JSONEncoder().encode(Archive(version: 1, vocabulary: memory.vocabulary, history: memory.history))
        try PrivateArchiveFile.write(data, to: url, maximumBytes: Self.maximumFileBytes)
    }
}
