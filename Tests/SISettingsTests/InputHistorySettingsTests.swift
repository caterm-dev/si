import Foundation
import Testing
import SICore
import SIStorage
@testable import SISettings

@MainActor
struct InputHistorySettingsTests {
    @Test func historyHasIndependentConsentAndCapturesActualSubmittedBytesOnly() async throws {
        let suite = "si-history-consent-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appending(path: suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = InputHistoryStore(url: directory.appending(path: "history.sqlite3"))
        defaults.set(true, forKey: "applicationMemory.historyEnabled")
        defaults.set(true, forKey: "applicationMemory.vocabularyEnabled")
        defaults.set(true, forKey: "personalization.enabled")
        var secure = false
        let settings = InputHistorySettings(defaults: defaults, store: store, allowsRecording: { !secure })
        await settings.start()
        let word = InputCandidate(text: "绿色", language: .simplifiedChinese, score: 1, consumedInputCount: 6)
        let prefix = InputCommit(input: "lu:se'", candidate: word, reason: .explicitSelection, remainingInput: "hao")
        settings.record(prefix)
        await settings.flush()
        let disabledPage = try await store.page()
        #expect(!settings.enabled && disabledPage.entries.isEmpty)
        defaults.set(false, forKey: "applicationMemory.vocabularyEnabled")
        settings.enabled = true
        settings.record(prefix)
        let english = InputCommit(input: "Hello", candidate: nil, reason: .literal)
        settings.record(english, suffix: " ")
        settings.record(InputCommit(input: "", candidate: nil, reason: .literal))
        secure = true
        settings.record(InputCommit(input: "private", candidate: nil, reason: .literal))
        secure = false
        let oldGeneration = settings.generation
        settings.enabled = false
        settings.enabled = true
        settings.record(english, expectedGeneration: oldGeneration)
        await settings.flush()
        let page = try await store.page()
        #expect(page.entries.count == 2)
        #expect(page.entries[0].input == "Hello" && page.entries[0].text == "Hello ")
        #expect(page.entries[1].input == "lu:se'" && page.entries[1].text == "绿色")
        #expect(!page.entries.contains { $0.input.contains("hao") })
        let restarted = InputHistorySettings(defaults: defaults, store: store, allowsRecording: { true })
        await restarted.start()
        #expect(restarted.enabled && restarted.canRecord)
        await restarted.refresh()
        #expect(restarted.entries.map(\.id) == page.entries.map(\.id))
    }

    @Test func clearRejectsQueuedRecordsAndDeleteDoesNotReturnAfterFlush() async throws {
        let suite = "si-history-clear-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appending(path: suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = InputHistoryStore(url: directory.appending(path: "history.sqlite3"))
        let settings = InputHistorySettings(defaults: defaults, store: store, allowsRecording: { true })
        await settings.start()
        settings.enabled = true
        for _ in 0..<25 { settings.record(InputCommit(input: "hello", candidate: nil, reason: .literal)) }
        settings.clear()
        settings.record(InputCommit(input: "duringclear", candidate: nil, reason: .literal))
        await settings.flush()
        #expect(try await store.page().entries.isEmpty)
        #expect(!settings.isSaving && !settings.isClearing && settings.canRecord)
        settings.record(InputCommit(input: "new", candidate: nil, reason: .automaticConfirmation))
        await settings.flush()
        await settings.refresh()
        let id = try #require(settings.entries.first?.id)
        settings.remove(id: id)
        await settings.flush()
        let deletedPage = try await store.page()
        #expect(settings.entries.isEmpty && deletedPage.entries.isEmpty)
    }

    @Test func writeFailurePausesRecordingAndRetryPreservesEachEventOnce() async throws {
        let suite = "si-history-retry-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appending(path: suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let url = directory.appending(path: "history.sqlite3")
        let store = InputHistoryStore(url: url)
        let settings = InputHistorySettings(defaults: defaults, store: store, allowsRecording: { true })
        await settings.start()
        let original = try Data(contentsOf: url)
        let corrupt = Data("Synthetic failure".utf8)
        try corrupt.write(to: url)
        settings.enabled = true
        settings.record(InputCommit(input: "hello", candidate: nil, reason: .literal))
        settings.record(InputCommit(input: "second", candidate: nil, reason: .literal))
        await settings.flush()
        #expect(settings.errorMessage != nil && settings.pendingRetryCount == 2 && !settings.canRecord)
        let incomplete = directory.appending(path: "incomplete.jsonl")
        await settings.export(to: incomplete)
        #expect(settings.exportError != nil && !FileManager.default.fileExists(atPath: incomplete.path))
        settings.record(InputCommit(input: "ignored", candidate: nil, reason: .literal))
        #expect(try Data(contentsOf: url) == corrupt)
        try original.write(to: url)
        settings.retrySaving()
        await settings.flush()
        #expect(settings.errorMessage == nil && settings.pendingRetryCount == 0 && settings.canRecord)
        #expect(try await store.page().entries.map(\.input) == ["second", "hello"])
        settings.retrySaving()
        await settings.flush()
        #expect(try await store.page().entries.count == 2)
        try corrupt.write(to: url)
        settings.record(InputCommit(input: "discarded", candidate: nil, reason: .literal))
        await settings.flush()
        #expect(settings.pendingRetryCount == 1)
        settings.clear()
        await settings.flush()
        settings.retrySaving()
        await settings.flush()
        #expect(settings.pendingRetryCount == 0 && settings.canRecord)
        #expect(try await store.page().entries.isEmpty)
    }

    @Test func exportIncludesQueuedRecordsOutsideTheCurrentSearchWithoutChangingConsent() async throws {
        let suite = "si-history-export-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appending(path: suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = InputHistoryStore(url: directory.appending(path: "history.sqlite3"))
        let settings = InputHistorySettings(defaults: defaults, store: store, allowsRecording: { true })
        await settings.start()
        settings.enabled = true
        settings.record(InputCommit(input: "hello", candidate: nil, reason: .literal))
        await settings.refresh(search: "missing")
        #expect(settings.entries.isEmpty)
        settings.record(InputCommit(input: "second", candidate: nil, reason: .literal))
        let archive = directory.appending(path: "history.jsonl")
        await settings.export(to: archive)
        #expect(settings.exportNotice != nil && settings.exportError == nil && !settings.isExporting)
        let data = try Data(contentsOf: archive)
        let footer = try #require(data.split(separator: 10).last)
        let summary = try #require(JSONSerialization.jsonObject(with: Data(footer)) as? [String: Any])
        #expect(summary["record_count"] as? Int == 2)
        #expect(settings.enabled && defaults.object(forKey: "inputHistory.allowModelTraining") == nil)
        await settings.export(to: directory.appending(path: "invalid.sqlite3"))
        #expect(settings.exportError != nil && settings.canRecord)
    }

}
