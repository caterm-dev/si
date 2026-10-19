import Foundation
import Testing
import SICore
import SIStorage
@testable import SISettings

@MainActor
struct PersonalizationSettingsTests {
    @Test func tokenRankingSurvivesRestartAndStopsOnPauseSecureInputAndClear() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let settings = fixture.settings()
        await settings.start()
        settings.isEnabled = true
        for _ in 0..<8 { settings.record(commit()) }
        await settings.flush()
        let permission = LearningPermission()
        let restarted = PersonalizationSettings(defaults: fixture.defaults, store: LearningStore(url: fixture.url),
                                                allowsLearning: { permission.allowed })
        await restarted.start()
        let engine = CandidateEngine()
        func first() -> String? {
            engine.candidates(for: "woshi", languages: [.simplifiedChinese], learning: restarted.rankingProfile).first?.text
        }
        #expect(first() == "我时")
        restarted.isEnabled = false
        #expect(first() == "我是")
        restarted.isEnabled = true
        permission.allowed = false
        #expect(first() == "我是")
        permission.allowed = true
        #expect(first() == "我时")
        restarted.clear()
        await restarted.flush()
        #expect(first() == "我是")
    }

    @Test func clearingOrTogglingConsentDiscardsAnExistingSessionContext() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let settings = fixture.settings()
        await settings.start()
        settings.isEnabled = true
        settings.contextEnabled = true
        var session = InputSession()
        session.configure(languages: [.english], usesContext: settings.usesContext, contextGeneration: settings.contextGeneration)
        session.append("open")
        let open = try #require(session.candidates.first { $0.text == "open" })
        _ = session.commitResult(open, reason: .explicitSelection)
        settings.isEnabled = false
        settings.isEnabled = true
        settings.clear()
        await settings.flush()
        session.configure(languages: [.english], usesContext: settings.usesContext, contextGeneration: settings.contextGeneration)
        session.append("fi")
        let file = try #require(session.candidates.first { $0.text == "file" })
        #expect(session.commitResult(file, reason: .explicitSelection).context == nil)
    }

    @Test func contextOptionIsSeparateOptInAndSurvivesRestart() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let settings = fixture.settings()
        await settings.start()
        settings.isEnabled = true
        #expect(!settings.contextEnabled)
        #expect(!settings.usesContext)
        let previous = try #require(CandidateContext(candidate: InputCandidate(text: "open", language: .english, score: 110)))
        let selection = InputCommit(input: "fi", candidate: InputCandidate(text: "file", language: .english, score: 85),
                                    reason: .explicitSelection, context: previous)
        settings.record(selection)
        #expect(settings.entries.count == 1)
        settings.contextEnabled = true
        settings.record(selection)
        #expect(settings.usesContext)
        #expect(settings.entries.count == 2)
        await settings.flush()
        let restarted = fixture.settings()
        await restarted.start()
        #expect(restarted.contextEnabled)
        #expect(restarted.entries.count == 2)
        restarted.isEnabled = false
        #expect(!restarted.usesContext)
        restarted.clear()
        await restarted.flush()
        #expect(restarted.entries.isEmpty)
    }

    @Test func previewsDoNotModifyRealLearningPreferences() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let preview = PersonalizationSettings(defaults: fixture.defaults, isPreview: true)
        preview.isEnabled = true
        preview.record(commit())
        await preview.flush()
        #expect(!fixture.defaults.bool(forKey: "personalization.enabled"))
        #expect(!FileManager.default.fileExists(atPath: fixture.url.path))
    }

    @Test func secureEventInputSuppressesLearningAndRanking() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let settings = PersonalizationSettings(defaults: fixture.defaults, store: LearningStore(url: fixture.url),
                                               allowsLearning: { false })
        await settings.start()
        settings.isEnabled = true
        settings.record(commit())
        #expect(settings.entries.isEmpty)
        #expect(settings.rankingProfile.entries.isEmpty)
    }

    @Test func learningIsOptInAndPauseStopsUpdatesAndRanking() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let settings = fixture.settings()
        await settings.start()
        #expect(!settings.isEnabled)
        settings.record(commit())
        #expect(settings.entries.isEmpty)
        settings.isEnabled = true
        settings.record(commit())
        #expect(settings.entries.count == 1)
        #expect(!settings.rankingProfile.entries.isEmpty)
        let entries = settings.entries
        settings.isEnabled = false
        settings.record(commit())
        #expect(settings.entries == entries)
        #expect(settings.rankingProfile.entries.isEmpty)
        await settings.flush()
        let restarted = fixture.settings()
        await restarted.start()
        #expect(!restarted.isEnabled)
        #expect(restarted.entries.count == 1)
        restarted.isEnabled = true
        #expect(!restarted.rankingProfile.entries.isEmpty)
    }

    @Test func deletingOnePreferenceIsDurable() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let settings = fixture.settings()
        await settings.start()
        settings.isEnabled = true
        settings.record(commit())
        settings.record(commit(text: "是"))
        settings.remove(id: try #require(settings.entries.first { $0.text == "时" }?.id))
        await settings.flush()
        let restarted = fixture.settings()
        await restarted.start()
        #expect(restarted.entries.map(\.text) == ["是"])
        #expect(settings.errorMessage == nil)
    }

    @Test func clearWinsOverDebouncedLearningAndPreservesLanguageSettings() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let language = LanguageSettings(defaults: fixture.defaults)
        language.chineseEnabled = false
        let settings = fixture.settings()
        await settings.start()
        settings.isEnabled = true
        settings.record(commit())
        settings.clear()
        await settings.flush()
        let restarted = fixture.settings()
        await restarted.start()
        #expect(restarted.entries.isEmpty)
        #expect(!LanguageSettings(defaults: fixture.defaults).chineseEnabled)
    }

    @Test func corruptStorePausesLearningUntilExplicitClear() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try Data("broken".utf8).write(to: fixture.url)
        let settings = fixture.settings()
        await settings.start()
        settings.isEnabled = true
        settings.record(commit())
        #expect(settings.errorMessage != nil)
        #expect(settings.entries.isEmpty)
        #expect(settings.rankingProfile.entries.isEmpty)
        settings.clear()
        await settings.flush()
        #expect(settings.errorMessage == nil)
        settings.record(commit())
        await settings.flush()
        let restarted = fixture.settings()
        await restarted.start()
        #expect(restarted.entries.count == 1)
    }

    @Test func saveErrorIsVisibleAndCanBeRetried() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try Data("parent is a file".utf8).write(to: fixture.url)
        let store = LearningStore(url: fixture.url.appending(path: "learning.json"))
        let settings = PersonalizationSettings(defaults: fixture.defaults, store: store, allowsLearning: { true })
        await settings.start()
        settings.isEnabled = true
        settings.record(commit())
        await settings.flush()
        #expect(settings.errorMessage != nil)
        #expect(settings.entries.count == 1)
        try FileManager.default.removeItem(at: fixture.url)
        await settings.flush()
        #expect(settings.errorMessage == nil)
        #expect(!settings.isSaving)
    }

    private func commit(text: String = "时") -> InputCommit {
        InputCommit(input: "shi", candidate: InputCandidate(text: text, language: .simplifiedChinese, score: 99),
                    reason: .explicitSelection)
    }

    @MainActor
    private final class LearningPermission {
        var allowed = true
    }

    private struct Fixture {
        let name = "SI.Tests.\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appending(path: "si-settings-tests-\(UUID().uuidString)")
        let defaults: UserDefaults
        var url: URL { directory.appending(path: "preferences.json") }

        init() throws {
            defaults = try #require(UserDefaults(suiteName: name))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        @MainActor
        func settings() -> PersonalizationSettings {
            PersonalizationSettings(defaults: defaults, store: LearningStore(url: url), allowsLearning: { true })
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
