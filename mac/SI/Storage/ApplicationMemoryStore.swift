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

    private struct LegacyArchive: Decodable {
        struct Entry: Decodable {
            let applicationID: String
            let preference: LearnedPreference
            let count: Int
            let correctionCount: Int?
            let baseScore: Double
            let lexicalTokenCount: Int?
        }
        let vocabulary: [Entry]
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
        guard (1...4).contains(archive.version) else { throw StoreError.unsupportedVersion }
        let entries: [ApplicationVocabularyEntry]
        if archive.version < 4 {
            let legacy = try JSONDecoder().decode(LegacyArchive.self, from: data)
            entries = legacy.vocabulary.compactMap { entry in
                guard !entry.applicationID.isEmpty, entry.applicationID.utf8.count <= 255,
                      !entry.applicationID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
                let old = entry.preference
                // v1/2 mixed defaults and corrections. v3 strengths are reliable but have no selection timestamp.
                let preference = LearnedPreference(input: old.input, text: old.text, language: old.language,
                    strength: archive.version < 3 ? 0 : old.strength, lastUsed: old.lastUsed,
                    isMixed: old.mixed == true, context: old.context)
                return ApplicationVocabularyEntry(preference: preference, count: entry.count,
                    baseScore: entry.baseScore, lexicalTokenCount: entry.lexicalTokenCount,
                    correctionCount: archive.version < 3 ? 0 : entry.correctionCount ?? 0)
            }
        } else {
            entries = archive.vocabulary
        }
        let memory = ApplicationMemory(vocabulary: entries, now: now)
        // Atomically remove app scope/history, merge duplicates, and retain existing records without age expiry.
        // Decoding errors never rewrite the original; migration write errors pause loading.
        if archive.version < 4 || memory.vocabulary != archive.vocabulary { try write(memory) }
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
        let data = try JSONEncoder().encode(Archive(version: 4, vocabulary: memory.vocabulary))
        try PrivateArchiveFile.write(data, to: url, maximumBytes: Self.maximumFileBytes)
    }
}
