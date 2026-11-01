import Foundation
import SQLite3
import Testing
import SICore
@testable import SIStorage

struct InputHistoryStoreTests {
    private let oldDate = Date(timeIntervalSince1970: 946_684_800)

    @Test func repeatedSubmissionsRetainExactBytesAndRetryIsIdempotent() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "history.sqlite3")
        let store = InputHistoryStore(url: url)
        let source = "LÜ'SE' e\u{301}\u{0}"
        let output = "绿色 e\u{301}\u{0} end "
        let first = InputHistoryEntry(createdAt: oldDate, input: source, text: output,
                                      language: .simplifiedChinese, isMixed: true, reason: .explicitSelection)
        let repeated = InputHistoryEntry(createdAt: oldDate, input: source, text: output,
                                         language: .simplifiedChinese, isMixed: true, reason: .explicitSelection)
        try await store.append([first, repeated])
        try await store.append([first])
        let restarted = InputHistoryStore(url: url)
        let page = try await restarted.page()
        #expect(page.entries.map(\.id) == [repeated.id, first.id])
        let restored = try #require(page.entries.last)
        #expect(restored.input.utf8.elementsEqual(source.utf8))
        #expect(restored.text.utf8.elementsEqual(output.utf8))
        #expect(restored.createdAt == oldDate && restored.isMixed && restored.reason == .explicitSelection)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    @Test func permanentHistoryHasNoLearningCapAndKeysetPagesSurviveNewInsertions() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = InputHistoryStore(url: directory.appending(path: "history.sqlite3"))
        let entries = (0..<5_005).map { index in
            InputHistoryEntry(createdAt: oldDate, input: "synthetic\(index)", text: "测试\(index)",
                              language: .simplifiedChinese, reason: .defaultAcceptance)
        }
        try await store.append(entries)
        let first = try await store.page(limit: 1_000)
        #expect(first.entries.count == 100 && first.entries.first?.id == entries.last?.id)
        let newer = InputHistoryEntry(createdAt: oldDate.addingTimeInterval(-86_400), input: "english", text: "English ",
                                      language: .english, reason: .literal)
        try await store.append([newer])
        var visited = first.entries.map(\.id)
        var cursor = first.nextCursor
        while let before = cursor {
            let page = try await store.page(before: before)
            visited += page.entries.map(\.id)
            cursor = page.nextCursor
        }
        #expect(visited == entries.reversed().map(\.id))
        #expect(Set(visited).count == 5_005)
        #expect(try await store.page().entries.first?.id == newer.id)
    }

    @Test func searchDeleteAndClearAreIndependentOfLearning() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "history.sqlite3")
        let store = InputHistoryStore(url: url)
        try await store.prepare()
        let learningURL = directory.appending(path: "learning.json")
        let learning = Data("Synthetic separate preferences".utf8)
        try learning.write(to: learningURL)
        let literal = InputHistoryEntry(input: "%' OR 1=1 --", text: "literal", language: nil, reason: .literal)
        let chinese = InputHistoryEntry(input: "nihao", text: "你好", language: .simplifiedChinese, reason: .defaultAcceptance)
        try await store.append([literal, chinese])
        #expect(try await store.page(search: "%' OR 1=1 --").entries.map(\.id) == [literal.id])
        #expect(try await store.page(search: "NIHAO").entries.map(\.id) == [chinese.id])
        #expect(try await store.page(search: "你好").entries.map(\.id) == [chinese.id])
        try await store.remove(id: literal.id)
        #expect(try await store.page().entries.map(\.id) == [chinese.id])
        try await store.clear()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(try Data(contentsOf: learningURL) == learning)
        #expect(try await store.page().entries.isEmpty)
    }

    @Test func invalidBatchAndCorruptOrFutureSchemaNeverReplaceExistingData() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "history.sqlite3")
        let store = InputHistoryStore(url: url)
        let valid = InputHistoryEntry(input: "hello", text: "hello ", language: .english, reason: .defaultAcceptance)
        let invalid = InputHistoryEntry(input: "", text: "invalid", language: nil, reason: .literal)
        await #expect(throws: (any Error).self) { try await store.append([valid, invalid]) }
        #expect(try await store.page().entries.isEmpty)
        try execute("ALTER TABLE input_history RENAME TO unexpected", at: url)
        let invalidSchema = try Data(contentsOf: url)
        await #expect(throws: (any Error).self) { try await store.prepare() }
        #expect(try Data(contentsOf: url) == invalidSchema)
        try await store.clear()
        try await store.prepare()
        try execute("PRAGMA user_version = 99", at: url)
        let future = try Data(contentsOf: url)
        await #expect(throws: (any Error).self) { try await store.append([valid]) }
        #expect(try Data(contentsOf: url) == future)
        try await store.clear()
        let corrupt = Data("Synthetic invalid SQLite database".utf8)
        try corrupt.write(to: url)
        await #expect(throws: (any Error).self) { try await store.prepare() }
        #expect(try Data(contentsOf: url) == corrupt)
        try await store.clear()
        try await store.append([valid])
        #expect(try await store.page().entries.map(\.id) == [valid.id])
    }

    @Test func exportRoundTripsThroughTheDeveloperRestoreToolWithExactBytes() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "history.sqlite3")
        let store = InputHistoryStore(url: url)
        let first = InputHistoryEntry(createdAt: oldDate, input: "LÜ'SE' e\u{301}\u{0}", text: "绿色 e\u{301}\u{0} ",
                                      language: .simplifiedChinese, reason: .explicitSelection)
        let second = InputHistoryEntry(createdAt: oldDate, input: "Hello", text: "Hello ", language: .english, reason: .literal)
        try await store.append([first, second])
        let archive = directory.appending(path: "SI-Input-History.jsonl")
        let count = try await store.export(to: archive, now: oldDate)
        #expect(count == 2)
        let firstLine = try #require(Data(contentsOf: archive).split(separator: 10).first)
        let manifest = try #require(JSONSerialization.jsonObject(with: Data(firstLine)) as? [String: Any])
        #expect(manifest["allow_model_training"] == nil && manifest["training_notice_version"] == nil)
        let attributes = try FileManager.default.attributesOfItem(atPath: archive.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let restoredURL = directory.appending(path: "restored.sqlite3")
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = ["python3", root.appending(path: "scripts/input_history.py").path,
                             "restore", archive.path, "--output", restoredURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let restored = InputHistoryStore(url: restoredURL)
        let rows = try await restored.page().entries
        #expect(rows.map(\.id) == [second.id, first.id])
        #expect(rows.last?.input.utf8.elementsEqual(first.input.utf8) == true)
        #expect(rows.last?.text.utf8.elementsEqual(first.text.utf8) == true)
        #expect(rows.first == second)
    }

    @Test func exportFailurePreservesExistingDestinationAndProtectsTheLiveDatabase() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "history.sqlite3")
        let store = InputHistoryStore(url: url)
        try await store.append([InputHistoryEntry(input: "hello", text: "hello", language: .english, reason: .literal)])
        let originalDatabase = try Data(contentsOf: url)
        await #expect(throws: (any Error).self) { try await store.export(to: url) }
        #expect(try Data(contentsOf: url) == originalDatabase)
        let archive = directory.appending(path: "SI-Input-History.jsonl")
        try Data("Synthetic previous file".utf8).write(to: archive)
        let count = try await store.export(to: archive)
        #expect(count == 1)
        let exported = try Data(contentsOf: archive)
        let firstLine = try #require(exported.split(separator: 10).first)
        let manifest = try #require(JSONSerialization.jsonObject(with: Data(firstLine)) as? [String: Any])
        #expect(Set(manifest.keys) == ["type", "format", "version", "scope", "exported_at_unix"])
        try Data("Synthetic invalid database".utf8).write(to: url)
        await #expect(throws: (any Error).self) { try await store.export(to: archive) }
        #expect(try Data(contentsOf: archive) == exported)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy { !$0.hasPrefix(".si-history-export-") })
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "si-history-tests-\(UUID().uuidString)")
    }

    private func execute(_ sql: String, at url: URL) throws {
        var connection: OpaquePointer?
        guard sqlite3_open(url.path, &connection) == SQLITE_OK, let connection else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_close(connection) }
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
    }
}
