import Foundation
import Testing
import SIStorage
import SICore

struct AppLearningStoreTests {
    @Test func createsSeparatePrivateModelsAndClearLeavesOtherAppsIntact() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "si-app-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppLearningStore(root: root)
        let paragraph = "你好世界 hello world"
        #expect(try await store.observe(bundle: "org.example.one", paragraphs: [paragraph]))
        #expect(try await !store.observe(bundle: "org.example.one", paragraphs: [paragraph]))
        #expect(try await !store.observe(bundle: "org.example.one", paragraphs: []))
        #expect(try await store.observe(bundle: "org.example.one", paragraphs: [paragraph]))
        #expect(try await store.observe(bundle: "org.example.two", paragraphs: [paragraph]))
        let profiles = try await store.profiles()
        #expect(profiles.map(\.bundle) == ["org.example.one", "org.example.two"])
        #expect(profiles.allSatisfy { $0.words > 0 && $0.grams > 0 })
        for profile in profiles {
            let directory = root.appending(path: profile.id)
            let snapshot = directory
            #expect(Set(try FileManager.default.contentsOfDirectory(atPath: snapshot.path)) == ["app.silex", "app.sigram", "meta-v1.txt", "model.lock"])
            let permissions = try FileManager.default.attributesOfItem(atPath: snapshot.appending(path: "app.silex").path)
            #expect((permissions[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            #expect(!(try String(contentsOf: snapshot.appending(path: "meta-v1.txt"), encoding: .utf8)).contains(paragraph))
        }
        try await store.clear(bundle: "org.example.one")
        #expect(try await store.profiles().map(\.bundle) == ["org.example.two"])
        try await store.clear()
        #expect(try await store.profiles().isEmpty)
    }

    @Test func legacyMetadataCanBeViewedWithoutMigrationAndNextObservationUsesFixedFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "si-app-legacy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppLearningStore(root: root)
        let bundle = "org.example.legacy"
        _ = try await store.observe(bundle: bundle, paragraphs: ["你好世界 hello world"])
        let profile = try #require(try await store.profiles().first)
        await store.resetSessions()
        let directory = root.appending(path: profile.id)
        let legacy = directory.appending(path: "snapshot-a")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        for name in ["app.silex", "app.sigram", "meta-v1.txt"] {
            try FileManager.default.moveItem(at: directory.appending(path: name), to: legacy.appending(path: name))
        }
        let pointer = directory.appending(path: "current")
        #expect(FileManager.default.createFile(atPath: pointer.path, contents: Data("snapshot-a\n".utf8), attributes: [.posixPermissions: 0o600]))
        let reader = AppLearningStore(root: root)
        #expect(try await reader.profiles().map(\.bundle) == [bundle])
        #expect(FileManager.default.fileExists(atPath: pointer.path))
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "meta-v1.txt").path))
        #expect(try await reader.observe(bundle: bundle, paragraphs: ["你好世界 hello world"]))
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)) == ["app.silex", "app.sigram", "meta-v1.txt", "model.lock"])
        let metadata = try String(contentsOf: directory.appending(path: "meta-v1.txt"), encoding: .utf8).components(separatedBy: "\n")
        #expect(metadata[3] == "2")
    }

    @Test func snapshotBytesAreTheOnlySnapshotQuotaAndOversizeIsSkipped() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "si-app-byte-cap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppLearningStore(root: root)
        #expect(RustAppLearning.maximumSnapshotBytes == 512 * 1_024)
        #expect(try await !store.observe(bundle: "org.example.oversize", paragraphs: [String(repeating: "x", count: 512 * 1_024 + 1)]))
        #expect(!FileManager.default.fileExists(atPath: root.path))
        let paragraphs = Array(repeating: "hello world", count: 300)
        #expect(try await store.observe(bundle: "org.example.manyparagraphs", paragraphs: paragraphs))
        #expect(try await !store.observe(bundle: "org.example.manyparagraphs", paragraphs: [String(repeating: "界", count: 512 * 1_024 / 3 + 1)]))
        #expect(try await !store.observe(bundle: "org.example.manyparagraphs", paragraphs: paragraphs))
    }

    @Test func appCountHasNoSeparateQuota() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "si-app-count-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppLearningStore(root: root)
        for index in 0..<17 {
            #expect(try await store.observe(bundle: "org.example.app\(index)", paragraphs: ["hello world"]))
        }
        #expect(try await store.profiles().count == 17)
    }
}
