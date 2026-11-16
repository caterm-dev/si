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

    @Test func personalPhrasesEditTheSharedUserLexiconWithoutEnablingLearning() async throws {
        let suite = "si-phrase-editor-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let profile = FileManager.default.temporaryDirectory.appending(path: "\(suite).si-user")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: profile)
        }
        let store = SentenceLearningStore(profile: profile)
        let settings = SentenceLearningSettings(defaults: defaults, store: store)
        await settings.start()
        let original = UserLexiconEntry(text: "Zornax", reading: "zornax", index: 1, count: 3)
        try await settings.editEntry(old: nil, new: original)
        #expect(!settings.enabled)
        #expect(settings.modelForInput == nil)
        #expect(settings.entries == [original])
        let updated = UserLexiconEntry(text: "Talvexa", reading: "talvexa", index: 1, count: 8)
        try await settings.editEntry(old: original, new: updated)
        let snapshot = try await store.load()
        #expect(snapshot.entries == [updated])
        settings.enabled = true
        #expect(settings.modelForInput != nil)
        do {
            try await settings.editEntry(old: original, new: nil)
            Issue.record("A stale entry must not remove a newer row")
        } catch {}
        #expect(settings.entries == [updated])
        try await settings.editEntry(old: updated, new: nil)
        #expect(settings.entries.isEmpty)
        #expect(try await store.load().entries.isEmpty)
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
        let empty = try await store.load()
        #expect(empty.model == nil && empty.recentSamples.isEmpty)

        // A file at the profile path makes the first write fail without changing the sample.
        try oldBytes.write(to: profile)
        let fullField = String(repeating: "a ", count: 1_100) + "\n"
            + String(repeating: "Zornax Quivora\n", count: 40) + "Talvexa"
        settings.record(fullField, coverage: .beforeCaret, expectedGeneration: settings.generation)
        #expect(settings.captureStatus == .queued(.beforeCaret))
        await settings.flush()
        #expect(settings.canRetry && !settings.canCapture)
        #expect(inputSnapshot().sentenceModel == nil)
        #expect(settings.recentSamples.isEmpty)
        try FileManager.default.removeItem(at: profile)
        settings.retry()
        await settings.flush()
        #expect(!settings.canRetry && settings.errorMessage == nil)
        #expect(settings.captureStatus == .saved(.beforeCaret))
        #expect(settings.recentSamples == [fullField])
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
        let loaded = try await store.load()
        let reloaded = try #require(loaded.model)
        #expect(loaded.recentSamples == [fullField])
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
        #expect(settings.captureStatus == .queued(.fullField) || settings.captureStatus == .saved(.fullField))
        memory.vocabularyEnabled = true
        memory.recordVocabulary(commit)
        settings.clear()
        #expect(inputSnapshot().sentenceModel == nil)
        #expect(inputSnapshot().vocabulary.count == 1)
        #expect(settings.captureStatus == nil)
        await settings.flush()
        await memory.flush()
        let cleared = try await store.load()
        #expect(cleared.model == nil && cleared.recentSamples.isEmpty)
        #expect(settings.recentSamples.isEmpty)
        #expect(try Data(contentsOf: archive) == oldBytes)
        settings.deleteRetiredHistory()
        await settings.flush()
        #expect(!FileManager.default.fileExists(atPath: archive.path))
    }

    @Test func recentSamplesKeepTheLastTenCapturesAcrossRestartAndRetry() async throws {
        let suite = "si-recent-samples-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let profile = FileManager.default.temporaryDirectory.appending(path: "\(suite).si-user")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: profile)
        }
        let store = SentenceLearningStore(profile: profile)
        let settings = SentenceLearningSettings(defaults: defaults, store: store, allowsRecording: { true })
        await settings.start()
        settings.enabled = true
        let fields = (1...11).map { "Synthetic sample \($0)\r\n第二行👩‍💻\0" }
        for field in fields {
            settings.record(field, expectedGeneration: settings.generation)
        }
        #expect(settings.recentSamples.isEmpty)
        await settings.flush()
        let expected = Array(fields.suffix(10))
        #expect(settings.recentSamples.map { Array($0.utf8) } == expected.map { Array($0.utf8) })

        // The same text captured twice is two samples. A retried batch is applied once.
        let repeatField = try #require(fields.last)
        let batchID = UUID()
        _ = try await store.ingest([repeatField], batchID: batchID)
        _ = try await store.ingest(["Retry must not add this text"], batchID: batchID)
        let restarted = SentenceLearningSettings(defaults: defaults, store: store)
        await restarted.start()
        #expect(restarted.recentSamples == Array(expected.dropFirst()) + [repeatField])
        restarted.clear()
        await restarted.flush()
        #expect(restarted.recentSamples.isEmpty)
        #expect(try await store.load().recentSamples.isEmpty)
    }
}
