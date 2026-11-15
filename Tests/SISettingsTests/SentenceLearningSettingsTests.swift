import Foundation
import Testing
import SICore
import SIStorage
@testable import SISettings

@MainActor
struct SentenceLearningSettingsTests {
    private final class SecureInput {
        var enabled = false
    }

    @Test func appIngestionPublishesPersistentCandidatesAndClearInvalidatesQueuedText() async throws {
        let suite = "si-sentence-learning-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appending(path: suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let archive = directory.appending(path: "sentences.sqlite3")
        let oldBytes = Data("synthetic legacy archive".utf8)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try oldBytes.write(to: archive)
        let profile = directory.appending(path: "model.si-user")
        let store = SentenceLearningStore(profile: profile)
        let secure = SecureInput()
        defaults.set(false, forKey: "sentenceHistory.enabled")
        let memory = ApplicationMemorySettings(defaults: defaults,
            store: ApplicationMemoryStore(url: directory.appending(path: "memory.json")),
            sentenceStore: store, retiredSentenceHistory: InputHistoryStore(url: archive),
            allowsRecording: { !secure.enabled })
        let settings = memory.sentences

        #expect(settings.enabled)
        #expect(defaults.object(forKey: "sentenceHistory.enabled") == nil)
        #expect(defaults.object(forKey: "sentenceLearning.enabled") == nil)
        settings.enabled = false
        defaults.set(true, forKey: "sentenceHistory.enabled")
        let restarted = SentenceLearningSettings(defaults: defaults, store: store)
        #expect(!restarted.enabled)
        #expect(defaults.object(forKey: "sentenceHistory.enabled") == nil)
        settings.enabled = true
        await memory.start()
        await settings.start()
        #expect(settings.hasRetiredHistory)
        #expect(try Data(contentsOf: archive) == oldBytes)
        #expect(!memory.usesVocabulary)
        #expect(memory.snapshot().sentenceModel == nil)

        memory.vocabularyEnabled = true
        #expect(settings.canCapture)
        let stale = settings.generation
        settings.enabled = false
        settings.enabled = true
        settings.record("Zornax", expectedGeneration: stale)
        settings.record("one\ntwo", expectedGeneration: settings.generation)
        await settings.flush()
        #expect(try await store.load() == nil)

        // A file at the profile path makes the first write fail without changing the sample.
        try oldBytes.write(to: profile)
        settings.record("Zornax Quivora", expectedGeneration: settings.generation)
        await settings.flush()
        #expect(settings.canRetry && !settings.canCapture)
        #expect(memory.snapshot().sentenceModel == nil)
        try FileManager.default.removeItem(at: profile)
        settings.retry()
        await settings.flush()
        #expect(!settings.canRetry && settings.errorMessage == nil)
        let engine = CandidateEngine()
        func candidates(_ snapshot: ApplicationMemorySnapshot) -> [InputCandidate] {
            engine.candidates(for: "zornax", languages: [.english], applicationMemory: snapshot)
        }
        #expect(candidates(.empty).allSatisfy { $0.text != "Zornax" })
        #expect(candidates(memory.snapshot()).contains { $0.text == "Zornax" })
        let reloaded = try #require(try await store.load())
        #expect(candidates(ApplicationMemorySnapshot(sentenceModel: reloaded)).contains { $0.text == "Zornax" })

        secure.enabled = true
        #expect(memory.snapshot().sentenceModel == nil)
        secure.enabled = false
        settings.enabled = false
        #expect(memory.snapshot().sentenceModel == nil)
        settings.enabled = true
        memory.vocabularyEnabled = false
        #expect(memory.snapshot().sentenceModel == nil)
        memory.vocabularyEnabled = true

        settings.record("Vexora", expectedGeneration: settings.generation)
        memory.clearAll()
        #expect(memory.snapshot().sentenceModel == nil)
        await settings.flush()
        await memory.flush()
        #expect(try await store.load() == nil)
        #expect(try Data(contentsOf: archive) == oldBytes)
        settings.deleteRetiredHistory()
        await settings.flush()
        #expect(!FileManager.default.fileExists(atPath: archive.path))
    }
}
