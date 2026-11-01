import Foundation
import Testing
import SICore
@testable import SIStorage

struct ApplicationMemoryStoreTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test(arguments: [1, 2, 3])
    func legacyAppScopesMergeAtomicallyWithoutGuessingRecentSelections(version: Int) async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "application-memory-v1.json")
        let legacyURL = directory.appending(path: "preferences-v1.json")
        let legacyBytes = Data("Synthetic inactive shared archive".utf8)
        try legacyBytes.write(to: legacyURL)
        let oldDate = now.addingTimeInterval(-365 * 86_400)
        let old = ApplicationVocabularyEntry(
            preference: LearnedPreference(input: "shi", text: "是", language: .simplifiedChinese, strength: 5, lastUsed: oldDate),
            count: 5, baseScore: -7.15, lexicalTokenCount: 1, correctionCount: 3)
        var first = try legacyRow(old, app: "org.example.editor")
        let newer = ApplicationVocabularyEntry(
            preference: LearnedPreference(input: "shi", text: "是", language: .simplifiedChinese, strength: 2, lastUsed: now),
            count: 7, baseScore: -3, lexicalTokenCount: 1, correctionCount: 4)
        let second = try legacyRow(newer, app: "org.example.other")
        if version < 3 { first.removeValue(forKey: "correctionCount") }
        let original = try JSONSerialization.data(withJSONObject: [
            "version": version, "vocabulary": [first, second], "history": ["Synthetic retired literal"],
        ])
        try original.write(to: url)
        let store = ApplicationMemoryStore(url: url, legacyLearningURL: legacyURL)
        let loaded = try await store.load(now: now)
        let merged = try #require(loaded.vocabulary.first)
        #expect(loaded.vocabulary.count == 1 && merged.count == 12)
        #expect(merged.correctionCount == (version < 3 ? 0 : 7))
        #expect(merged.preference.strength == (version < 3 ? 0 : 5))
        #expect(merged.lastSelected == nil && merged.preference.lastUsed == now && merged.baseScore == -3)
        let rewritten = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(rewritten["version"] as? Int == 4 && rewritten["history"] == nil)
        let rows = try #require(rewritten["vocabulary"] as? [[String: Any]])
        #expect(rows.first?["applicationID"] == nil)
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
                         Data(#"{"version":99,"vocabulary":[],"history":[]}"#.utf8),
                         Data(#"{"version":3,"vocabulary":[{"applicationID":3}]}"#.utf8)] {
            try original.write(to: url)
            await #expect(throws: (any Error).self) { try await ApplicationMemoryStore(url: url).load(now: now) }
            #expect(try Data(contentsOf: url) == original)
        }
    }

    @Test func exactChoiceSurvivesRestartWithoutDecayOrExpiry() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "application-memory-v1.json")
        let store = ApplicationMemoryStore(url: url)
        var memory = ApplicationMemory()
        let candidate = InputCandidate(text: "时刻", language: .simplifiedChinese, score: -500, lexicalTokenCount: 1)
        memory.recordVocabulary(InputCommit(input: "shike", candidate: candidate, reason: .explicitSelection), now: now)
        try await store.save(memory, revision: 1)
        let later = now.addingTimeInterval(365 * 86_400)
        let restored = try await ApplicationMemoryStore(url: url).load(now: later)
        #expect(restored == memory && restored.vocabulary.first?.lastSelected == now)
        let snapshot = restored.snapshot(vocabularyEnabled: true, now: later)
        let results = CandidateEngine().candidates(for: "shike", languages: [.simplifiedChinese],
            learning: snapshot.learning, now: later, applicationMemory: snapshot)
        #expect(results.first?.id == candidate.id && results.last?.text == "shike")
    }

    @Test func newSavesContainOnlyGlobalVocabularyAndOlderWritesCannotUndoDeletion() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "application-memory-v1.json")
        let store = ApplicationMemoryStore(url: url)
        let old = entry()
        let memory = ApplicationMemory(vocabulary: [old], now: now)
        try await store.save(memory, revision: 1)
        let archive = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(Set(archive.keys) == ["version", "vocabulary"])
        #expect(archive["version"] as? Int == 4)
        try await store.erase(revision: 3)
        try await store.save(memory, revision: 2)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(try await store.load(now: now).vocabulary.isEmpty)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "si-vocabulary-store-tests-\(UUID().uuidString)")
    }

    private func entry() -> ApplicationVocabularyEntry {
        ApplicationVocabularyEntry(
            preference: LearnedPreference(input: "shi", text: "是", language: .simplifiedChinese, strength: 5, lastUsed: now),
            count: 5, baseScore: -7.15, lexicalTokenCount: 1)
    }

    private func legacyRow(_ entry: ApplicationVocabularyEntry, app: String) throws -> [String: Any] {
        var row = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        row["applicationID"] = app
        return row
    }
}
