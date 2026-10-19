import Foundation
import Testing
import SICore
@testable import SIStorage

struct UserDictionaryStoreTests {
    @Test func restartPermissionsAndDeletionOrdering() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "phrases.json")
        let store = UserDictionaryStore(url: url)
        let dictionary = try fixtureDictionary()
        #expect(try await store.load().entries.isEmpty)
        try await store.save(dictionary, revision: 1)
        #expect(try await UserDictionaryStore(url: url).load() == dictionary)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        try await store.erase(revision: 3)
        try await store.save(dictionary, revision: 2)
        #expect(try await UserDictionaryStore(url: url).load().entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func badStoreIsPreservedUntilExplicitClear() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "phrases.json")
        let data = Data("broken json".utf8)
        try data.write(to: url)
        let store = UserDictionaryStore(url: url)
        await #expect(throws: (any Error).self) { try await store.load() }
        #expect(try Data(contentsOf: url) == data)
        try await store.erase(revision: 1)
        #expect(try await store.load().entries.isEmpty)
    }

    @Test func importExportUsesSelectedFileWithoutChangingPrivateStore() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let privateURL = directory.appending(path: "private/phrases.json")
        let exportURL = directory.appending(path: "export.json")
        let store = UserDictionaryStore(url: privateURL)
        let dictionary = try fixtureDictionary()
        let data = try await store.export(dictionary)
        try data.write(to: exportURL)
        #expect(try await store.readImport(at: exportURL) == dictionary)
        #expect(!FileManager.default.fileExists(atPath: privateURL.path))
        await #expect(throws: (any Error).self) {
            try await store.readImport(at: directory.appending(path: "missing.json"))
        }
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "si-phrase-tests-\(UUID().uuidString)")
    }

    private func fixtureDictionary() throws -> UserDictionary {
        try UserDictionary(entries: [UserPhrase(input: "xm", text: "测试项目", language: .simplifiedChinese)])
    }
}
