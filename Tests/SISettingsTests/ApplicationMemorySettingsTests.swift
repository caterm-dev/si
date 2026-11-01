import Foundation
import Testing
import SICore
import SIStorage
@testable import SISettings

@MainActor
struct ApplicationMemorySettingsTests {
    @Test func retiredHistoryConsentCannotEnableOrExcludeVocabulary() async throws {
        let suite = "si-retired-history-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appending(path: suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let url = directory.appending(path: "memory.json")
        let store = ApplicationMemoryStore(url: url)
        let app = "org.example.editor"
        defaults.set(true, forKey: "applicationMemory.historyEnabled")
        defaults.set([app], forKey: "applicationMemory.historyExclusions")
        let settings = ApplicationMemorySettings(defaults: defaults, store: store, allowsRecording: { true })
        #expect(defaults.object(forKey: "applicationMemory.historyEnabled") == nil)
        #expect(defaults.object(forKey: "applicationMemory.historyExclusions") == nil)
        await settings.start()
        #expect(!settings.vocabularyEnabled && !settings.usesVocabulary(in: app))
        #expect(settings.applicationIDs.isEmpty)
        settings.vocabularyEnabled = true
        let candidate = InputCandidate(text: "是", language: .simplifiedChinese, score: -7)
        settings.recordVocabulary(InputCommit(input: "shi", candidate: candidate, reason: .defaultAcceptance), applicationID: app)
        #expect(settings.snapshot(for: app).vocabulary.first?.count == 1)
        #expect(settings.snapshot(for: "org.example.other").vocabulary.isEmpty)
        settings.setVocabularyAllowed(false, applicationID: app)
        #expect(settings.snapshot(for: app).vocabulary.isEmpty)
        settings.setVocabularyAllowed(true, applicationID: app)
        await settings.flush()
        #expect(try await ApplicationMemoryStore(url: url).load().vocabulary.first?.count == 1)
    }
}
