import Foundation
import Testing
import SICore
@testable import SIStorage

struct ApplicationMemoryStoreTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func legacyArchiveDropsHistoryAndPreservesVocabularyAcrossRestart() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "application-memory-v1.json")
        let legacyURL = directory.appending(path: "preferences-v1.json")
        let legacyBytes = Data("Synthetic inactive shared archive".utf8)
        try legacyBytes.write(to: legacyURL)
        let entries = [entry(app: "org.example.editor"), entry(app: "org.example.other")]
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(entries))
        // The retired field is deliberately not a valid history-entry schema.
        let original = try JSONSerialization.data(withJSONObject: [
            "version": 1, "vocabulary": encoded, "history": ["Synthetic retired literal"],
        ])
        try original.write(to: url)
        let store = ApplicationMemoryStore(url: url, legacyLearningURL: legacyURL)
        let loaded = try await store.load(now: now)
        #expect(loaded.vocabulary.map(\.id).sorted() == entries.map(\.id).sorted())
        #expect(loaded.vocabulary.allSatisfy { $0.count == 5 && $0.correctionCount == 0 && $0.preference.strength == 0 })
        #expect(loaded.snapshot(applicationID: "org.example.editor", vocabularyEnabled: true, now: now).vocabulary.first?.id == entries[0].id)
        #expect(loaded.snapshot(applicationID: "org.example.editor", vocabularyEnabled: true, now: now).learning.entries.isEmpty)
        let rewritten = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(rewritten["version"] as? Int == 3)
        #expect(rewritten["history"] == nil)
        #expect(try await ApplicationMemoryStore(url: url).load(now: now) == loaded)
        #expect(try Data(contentsOf: legacyURL) == legacyBytes)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }

    @Test func unsupportedAndCorruptArchivesRemainUntouched() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "application-memory-v1.json")
        for original in [Data("broken json".utf8), Data(#"{"version":1,"vocabulary":"invalid","history":[]}"#.utf8),
                         Data(#"{"version":99,"vocabulary":[],"history":[]}"#.utf8)] {
            try original.write(to: url)
            let store = ApplicationMemoryStore(url: url)
            await #expect(throws: (any Error).self) { try await store.load(now: now) }
            #expect(try Data(contentsOf: url) == original)
        }
    }

    @Test func oldUsageStrengthIsResetAndPendingCorrectionsSurviveRestart() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "application-memory-v1.json")
        let old = entry(app: "org.example.editor")
        var row = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        row.removeValue(forKey: "correctionCount")
        try JSONSerialization.data(withJSONObject: ["version": 2, "vocabulary": [row]]).write(to: url)
        let store = ApplicationMemoryStore(url: url)
        var memory = try await store.load(now: now)
        #expect(memory.vocabulary.first?.count == 5 && memory.vocabulary.first?.preference.strength == 0)
        let candidate = InputCandidate(text: "是", language: .simplifiedChinese, score: -7, lexicalTokenCount: 1)
        let correction = InputCommit(input: "shi", candidate: candidate, reason: .explicitSelection)
        for _ in 0..<2 { memory.recordVocabulary(correction, applicationID: old.applicationID, now: now) }
        try await store.save(memory, revision: 1)
        let restarted = ApplicationMemoryStore(url: url)
        memory = try await restarted.load(now: now)
        #expect(memory.vocabulary.first?.correctionCount == 2 && memory.vocabulary.first?.preference.strength == 0)
        memory.recordVocabulary(correction, applicationID: old.applicationID, now: now)
        let profile = memory.snapshot(applicationID: old.applicationID, vocabularyEnabled: true, now: now).learning
        #expect(abs(profile.bonus(for: candidate, input: "shi", now: now) - 1) < 1e-12)
        try await restarted.save(memory, revision: 2)
        let restored = try await ApplicationMemoryStore(url: url).load(now: now)
        #expect(restored == memory)
        #expect(restored.vocabulary.first?.count == 8 && restored.vocabulary.first?.correctionCount == 3)
    }

    @Test func newSavesContainOnlyVocabularyAndOlderWritesCannotUndoDeletion() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "application-memory-v1.json")
        let store = ApplicationMemoryStore(url: url)
        let memory = ApplicationMemory(vocabulary: [entry(app: "org.example.editor")], now: now)
        try await store.save(memory, revision: 1)
        let archive = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(Set(archive.keys) == ["version", "vocabulary"])
        try await store.erase(revision: 3)
        try await store.save(memory, revision: 2)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(try await store.load(now: now).vocabulary.isEmpty)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "si-vocabulary-store-tests-\(UUID().uuidString)")
    }

    private func entry(app: String) -> ApplicationVocabularyEntry {
        ApplicationVocabularyEntry(applicationID: app,
            preference: LearnedPreference(input: "shi", text: "是", language: .simplifiedChinese, strength: 5, lastUsed: now),
            count: 5, baseScore: -7.15, lexicalTokenCount: 1)
    }
}
