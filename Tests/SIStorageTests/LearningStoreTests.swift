import Foundation
import Testing
import SICore
@testable import SIStorage

struct LearningStoreTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func schemaOneMigratesWithoutLosingMixedPreferences() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "preferences.json")
        let entry = LearnedPreference(input: "nihaoworld", text: "你好world", language: .simplifiedChinese,
                                      strength: 2, lastUsed: now)
        let encodedEntries = try JSONEncoder().encode([entry])
        let rows = try JSONSerialization.jsonObject(with: encodedEntries)
        let legacy = try JSONSerialization.data(withJSONObject: ["version": 1, "entries": rows])
        try legacy.write(to: url)
        let loaded = try await LearningStore(url: url).load(now: now)
        #expect(loaded.entries.count == 1)
        let mixed = InputCandidate(text: "你好world", language: .simplifiedChinese, score: 90, isMixed: true)
        #expect(loaded.bonus(for: mixed, input: "nihaoworld", now: now) > 0)
        let migrated = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(migrated["version"] as? Int == 2)
    }

    @Test func contextPairsRoundTripAndExpireWithTheSameRetentionPolicy() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "preferences.json")
        let context = try #require(CandidateContext(candidate: InputCandidate(text: "open", language: .english, score: 110)))
        let file = InputCandidate(text: "file", language: .english, score: 85)
        var profile = LearningProfile()
        profile.record(InputCommit(input: "fi", candidate: file, reason: .explicitSelection, context: context), now: now, learnContext: true)
        try await LearningStore(url: url).save(profile, revision: 1)
        let loaded = try await LearningStore(url: url).load(now: now)
        #expect(loaded == profile)
        #expect(loaded.entries.count == 2)
        #expect(try await LearningStore(url: url).load(now: now.addingTimeInterval(91 * 86_400)).entries.isEmpty)
    }

    @Test func roundTripAcrossStoreInstancesAndPrivatePermissions() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "learning/preferences.json")
        let store = LearningStore(url: url)
        #expect(try await store.load(now: now).entries.isEmpty)
        let profile = makeProfile()
        try await store.save(profile, revision: 1)
        #expect(try await LearningStore(url: url).load(now: now) == profile)
        let filePermissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        let directoryPermissions = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
        #expect(filePermissions?.intValue == 0o600)
        #expect(directoryPermissions?.intValue == 0o700)
    }

    @Test func clearCannotBeUndoneByOlderPendingWrite() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "preferences.json")
        let store = LearningStore(url: url)
        let profile = makeProfile()
        try await store.save(profile, revision: 1)
        try await store.erase(revision: 3)
        try await store.save(profile, revision: 2)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(try await LearningStore(url: url).load(now: now).entries.isEmpty)
        try await store.save(profile, revision: 4)
        #expect(try await LearningStore(url: url).load(now: now) == profile)
    }

    @Test func entryDeletionAndNewestSnapshotSurviveRestart() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "preferences.json")
        let store = LearningStore(url: url)
        let profile = makeProfile()
        try await store.save(profile, revision: 1)
        try await store.save(LearningProfile(), revision: 3)
        try await store.save(profile, revision: 2)
        #expect(try await LearningStore(url: url).load(now: now).entries.isEmpty)
    }

    @Test func corruptDataFailsWithoutBeingSilentlyOverwritten() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "preferences.json")
        let corrupt = Data("not-json".utf8)
        try corrupt.write(to: url)
        let store = LearningStore(url: url)
        await #expect(throws: (any Error).self) { try await store.load(now: now) }
        #expect(try Data(contentsOf: url) == corrupt)
        try await store.erase(revision: 1)
        #expect(try await store.load(now: now).entries.isEmpty)
    }

    @Test func unsupportedSchemaRemainsUntouched() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "preferences.json")
        let data = Data("{\"version\":999,\"entries\":[]}".utf8)
        try data.write(to: url)
        await #expect(throws: LearningStore.StoreError.unsupportedVersion) {
            try await LearningStore(url: url).load(now: now)
        }
        #expect(try Data(contentsOf: url) == data)
    }

    @Test func expirationIsPhysicallyPersistedOnLoad() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "preferences.json")
        try await LearningStore(url: url).save(makeProfile(), revision: 1)
        #expect(try await LearningStore(url: url).load(now: now.addingTimeInterval(91 * 86_400)).entries.isEmpty)
        // Loading again at the old date cannot resurrect expired data.
        #expect(try await LearningStore(url: url).load(now: now).entries.isEmpty)
    }

    @Test func oversizeAndUnwritableStoresReportFailure() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "preferences.json")
        try Data(repeating: 0, count: LearningStore.maximumFileBytes + 1).write(to: url)
        await #expect(throws: LearningStore.StoreError.tooLarge) {
            try await LearningStore(url: url).load(now: now)
        }
        let invalidURL = url.appending(path: "impossible/preferences.json")
        await #expect(throws: (any Error).self) {
            try await LearningStore(url: invalidURL).save(makeProfile(), revision: 1)
        }
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "si-learning-tests-\(UUID().uuidString)")
    }

    private func makeProfile() -> LearningProfile {
        var profile = LearningProfile()
        profile.record(InputCommit(input: "shi", candidate: InputCandidate(text: "时", language: .simplifiedChinese,
                                                                         score: 99), reason: .explicitSelection), now: now)
        return profile
    }
}
