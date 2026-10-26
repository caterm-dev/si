import Foundation
import Testing
import SICore
import SIStorage
import SILocalization
@testable import SISettings

@MainActor
struct UserDictionarySettingsTests {
    @Test func manualChangesPersistWithoutPersonalLearning() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let settings = fixture.settings()
        await settings.start()
        #expect(settings.canEdit)
        let phrase = try fixture.phrase()
        try settings.save(phrase)
        await settings.flush()
        let restarted = fixture.settings()
        await restarted.start()
        #expect(restarted.entries == [phrase])
        #expect(restarted.dictionaryForInput.entries == [phrase])
        #expect(restarted.errorMessage == nil)
    }

    @Test func deletionAndClearSurvivePendingSavesAndRestart() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let settings = fixture.settings()
        await settings.start()
        let phrase = try fixture.phrase()
        try settings.save(phrase)
        settings.remove(id: phrase.id)
        await settings.flush()
        let afterDeletion = fixture.settings()
        await afterDeletion.start()
        #expect(afterDeletion.entries.isEmpty)
        try settings.save(phrase)
        settings.clear()
        await settings.flush()
        let afterClear = fixture.settings()
        await afterClear.start()
        #expect(afterClear.entries.isEmpty)
    }

    @Test func importsMergeAndExportsRoundTripWithoutOverwritingLocalPhrase() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let settings = fixture.settings()
        await settings.start()
        let local = try fixture.phrase()
        try settings.save(local)
        let duplicate = try UserPhrase(input: local.input, text: local.text, language: local.language)
        let other = try UserPhrase(input: "sig", text: "Synthetic Name", language: .english)
        let imported = try UserDictionary(entries: [duplicate, other])
        let importURL = fixture.directory.appending(path: "import.json")
        try UserDictionaryArchive.encode(imported).write(to: importURL)
        await settings.importFile(importURL)
        await settings.flush()
        #expect(settings.entries.count == 2)
        #expect(settings.entries.contains { $0.id == local.id })
        #expect(settings.notice == L10n.format("Imported: %ld; already saved: %ld.", 1, 1))
        let data = try #require(await settings.exportData())
        #expect(try UserDictionaryArchive.decode(data).entries == settings.entries)
        let beforeInvalidImport = settings.entries
        try Data("bad json".utf8).write(to: importURL)
        await settings.importFile(importURL)
        await settings.flush()
        #expect(settings.errorMessage != nil)
        #expect(!settings.canRetrySaving)
        #expect(settings.entries == beforeInvalidImport)
    }

    @Test func unreadableArchiveIsNotSilentlyReset() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let original = Data("not a dictionary".utf8)
        try original.write(to: fixture.url)
        let settings = fixture.settings()
        await settings.start()
        #expect(!settings.canEdit)
        #expect(settings.dictionaryForInput.entries.isEmpty)
        #expect(settings.errorMessage != nil)
        #expect(try Data(contentsOf: fixture.url) == original)
        settings.clear()
        await settings.flush()
        #expect(settings.canEdit)
        #expect(settings.errorMessage == nil)
        try settings.save(fixture.phrase())
        await settings.flush()
        #expect(settings.entries.count == 1)
    }

    @Test func writeFailureCanBeRetriedWithoutLosingEdits() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try Data("blocked parent".utf8).write(to: fixture.url)
        let settings = UserDictionarySettings(store: UserDictionaryStore(url: fixture.url.appending(path: "phrases.json")),
                                               allowsSuggestions: { true })
        await settings.start()
        try settings.save(fixture.phrase())
        await settings.flush()
        #expect(settings.canRetrySaving)
        #expect(settings.entries.count == 1)
        try FileManager.default.removeItem(at: fixture.url)
        await settings.flush()
        #expect(settings.errorMessage == nil)
        #expect(!settings.isSaving)
    }

    @Test func secureInputSuppressesSuggestionsWithoutDeletingManualData() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let settings = UserDictionarySettings(store: UserDictionaryStore(url: fixture.url), allowsSuggestions: { false })
        await settings.start()
        try settings.save(fixture.phrase())
        await settings.flush()
        #expect(settings.entries.count == 1)
        #expect(settings.dictionaryForInput.entries.isEmpty)
    }

    @Test func previewNeverTouchesTheProvidedPersistentStore() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let settings = UserDictionarySettings(store: UserDictionaryStore(url: fixture.url), isPreview: true,
                                               allowsSuggestions: { true })
        try settings.save(fixture.phrase())
        await settings.flush()
        #expect(!FileManager.default.fileExists(atPath: fixture.url.path))
        #expect(settings.entries.count == 1)
    }

    private struct Fixture {
        let directory = FileManager.default.temporaryDirectory.appending(path: "si-dictionary-settings-\(UUID().uuidString)")
        var url: URL { directory.appending(path: "phrases.json") }

        init() throws { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }

        @MainActor func settings() -> UserDictionarySettings {
            UserDictionarySettings(store: UserDictionaryStore(url: url), allowsSuggestions: { true })
        }

        func phrase() throws -> UserPhrase {
            try UserPhrase(input: "xm", text: "测试项目", language: .simplifiedChinese, isPinned: true)
        }

        func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    }
}
