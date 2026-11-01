import Foundation
#if SWIFT_PACKAGE
import SICore
#endif

public actor ApplicationMemoryStore {
    public enum StoreError: Error { case unsupportedVersion }
    private struct Archive: Codable {
        let version: Int
        let vocabulary: [ApplicationVocabularyEntry]
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
        guard (1...3).contains(archive.version) else { throw StoreError.unsupportedVersion }
        var memory = ApplicationMemory(vocabulary: archive.vocabulary, now: now)
        if archive.version < 3 {
            // Old strengths mixed defaults and corrections, so they cannot be reused as preference evidence.
            memory = ApplicationMemory(vocabulary: memory.vocabulary.map { entry in
                let old = entry.preference
                let neutral = LearnedPreference(input: old.input, text: old.text, language: old.language,
                                                strength: 0, lastUsed: old.lastUsed, isMixed: old.mixed == true)
                return ApplicationVocabularyEntry(applicationID: entry.applicationID, preference: neutral, count: entry.count,
                    baseScore: entry.baseScore, lexicalTokenCount: entry.lexicalTokenCount)
            }, now: now)
        }
        // New writes also remove the retired history field from v1 archives.
        // Decoding errors propagate without rewriting; migration write errors pause loading.
        if archive.version < 3 || memory.vocabulary != archive.vocabulary { try write(memory) }
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
        let data = try JSONEncoder().encode(Archive(version: 3, vocabulary: memory.vocabulary))
        try PrivateArchiveFile.write(data, to: url, maximumBytes: Self.maximumFileBytes)
    }
}
