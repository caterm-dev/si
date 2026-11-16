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

    @Test(arguments: [true, false], [true, false, nil] as [Bool?])
    func movesOnlyActiveExplicitConsentToTheIndependentSwitch(previousPersonalLearning: Bool, previousSentenceLearning: Bool?) throws {
        let suite = "si-sentence-consent-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SentenceLearningStore(profile: FileManager.default.temporaryDirectory.appending(path: suite))
        defaults.set(previousPersonalLearning, forKey: ApplicationMemorySettings.vocabularyKey)
        defaults.set(previousSentenceLearning, forKey: "sentenceLearning.enabled")

        let expected = previousPersonalLearning && previousSentenceLearning == true
        let settings = SentenceLearningSettings(defaults: defaults, store: store)
        #expect(settings.enabled == expected)
        #expect(defaults.object(forKey: "sentenceLearning.enabled") == nil)
        settings.enabled = !expected
        defaults.set(false, forKey: ApplicationMemorySettings.vocabularyKey)
        #expect(SentenceLearningSettings(defaults: defaults, store: store).enabled == !expected)
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
        defaults.set(true, forKey: "sentenceHistory.enabled")
        let memory = ApplicationMemorySettings(defaults: defaults,
            store: ApplicationMemoryStore(url: directory.appending(path: "memory.json")),
            allowsRecording: { !secure.enabled })
        let settings = SentenceLearningSettings(defaults: defaults, store: store,
            retiredHistory: InputHistoryStore(url: archive), allowsRecording: { !secure.enabled })
        func inputSnapshot() -> ApplicationMemorySnapshot {
            memory.snapshot(sentenceModel: settings.modelForInput)
        }

        #expect(!settings.enabled)
        #expect(defaults.object(forKey: "sentenceHistory.enabled") == nil)
        await memory.start()
        await settings.start()
        #expect(settings.hasRetiredHistory)
        #expect(try Data(contentsOf: archive) == oldBytes)
        #expect(!memory.usesVocabulary)
        #expect(inputSnapshot().sentenceModel == nil)
        #expect(!settings.canCapture)

        settings.enabled = true
        #expect(settings.canCapture)
        let stale = settings.generation
        settings.enabled = false
        settings.enabled = true
        settings.record("Zornax", expectedGeneration: stale)
        settings.reportCapture(.skipped(.incompleteRange), expectedGeneration: stale)
        settings.record(" \n\t", expectedGeneration: settings.generation)
        await settings.flush()
        #expect(settings.captureStatus == nil)
        #expect(try await store.load() == nil)

        // A file at the profile path makes the first write fail without changing the sample.
        try oldBytes.write(to: profile)
        let fullField = String(repeating: "a ", count: 1_100) + "\n"
            + String(repeating: "Zornax Quivora\n", count: 40) + "Talvexa"
        settings.record(fullField, expectedGeneration: settings.generation)
        #expect(settings.captureStatus == .queued)
        await settings.flush()
        #expect(settings.canRetry && !settings.canCapture)
        #expect(inputSnapshot().sentenceModel == nil)
        try FileManager.default.removeItem(at: profile)
        settings.retry()
        await settings.flush()
        #expect(!settings.canRetry && settings.errorMessage == nil)
        #expect(settings.captureStatus == .saved)
        let engine = CandidateEngine()
        func candidates(_ snapshot: ApplicationMemorySnapshot) -> [InputCandidate] {
            engine.candidates(for: "zornax", languages: [.english], applicationMemory: snapshot)
        }
        #expect(candidates(.empty).allSatisfy { $0.text != "Zornax" })
        #expect(candidates(inputSnapshot()).contains { $0.text == "Zornax" })
        #expect(inputSnapshot().vocabulary.isEmpty)
        let slot = try String(contentsOf: profile.appending(path: "current"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let snapshot = profile.appending(path: "snapshot-\(slot)")
        #expect(FileManager.default.fileExists(atPath: snapshot.appending(path: "user.silex").path()))
        #expect(FileManager.default.fileExists(atPath: snapshot.appending(path: "user.sigram").path()))
        let reloaded = try #require(try await store.load())
        #expect(engine.candidates(for: "talvexa", languages: [.english],
            applicationMemory: ApplicationMemorySnapshot(sentenceModel: reloaded)).contains { $0.text == "Talvexa" })
        #expect(candidates(ApplicationMemorySnapshot(sentenceModel: reloaded)).contains { $0.text == "Zornax" })

        secure.enabled = true
        #expect(!settings.canCapture)
        #expect(settings.modelForInput == nil)
        #expect(inputSnapshot().sentenceModel == nil)
        secure.enabled = false
        memory.vocabularyEnabled = true
        let commit = InputCommit(input: "shi", candidate: InputCandidate(text: "是", language: .simplifiedChinese, score: -7),
                                 reason: .defaultAcceptance)
        memory.recordVocabulary(commit)
        #expect(inputSnapshot().vocabulary.count == 1)
        settings.enabled = false
        #expect(inputSnapshot().sentenceModel == nil)
        #expect(inputSnapshot().vocabulary.count == 1)
        settings.enabled = true
        memory.vocabularyEnabled = false
        #expect(inputSnapshot().sentenceModel != nil)
        #expect(inputSnapshot().vocabulary.isEmpty)

        settings.record("Vexora", expectedGeneration: settings.generation)
        memory.clearAll()
        await memory.flush()
        #expect(inputSnapshot().sentenceModel != nil)
        #expect(settings.captureStatus == .queued || settings.captureStatus == .saved)
        memory.vocabularyEnabled = true
        memory.recordVocabulary(commit)
        settings.clear()
        #expect(inputSnapshot().sentenceModel == nil)
        #expect(inputSnapshot().vocabulary.count == 1)
        #expect(settings.captureStatus == nil)
        await settings.flush()
        await memory.flush()
        #expect(try await store.load() == nil)
        #expect(try Data(contentsOf: archive) == oldBytes)
        settings.deleteRetiredHistory()
        await settings.flush()
        #expect(!FileManager.default.fileExists(atPath: archive.path))
    }
}
