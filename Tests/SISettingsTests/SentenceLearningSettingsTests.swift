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

    private struct SplitProvider: CandidateProvider {
        let language = InputLanguage.english

        func candidates(for input: String) -> [InputCandidate] {
            switch input {
            case "zornaxquivora":
                [InputCandidate(text: "Zornax", language: language, score: 1, consumedInputCount: 6)]
            case "quivora":
                [InputCandidate(text: "Quivora", language: language, score: 1)]
            default: []
            }
        }
    }

    private func confirmation(_ text: String, reason: CommitReason = .defaultAcceptance) -> InputCommit {
        InputCommit(input: text.lowercased(), candidate: InputCandidate(text: text, language: .english, score: -7),
                    reason: reason)
    }

    @Test func personalPhrasesEditTheActiveUserLexicon() async throws {
        let suite = "si-phrase-editor-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let profile = FileManager.default.temporaryDirectory.appending(path: "\(suite).si-user")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: profile)
        }
        let store = SentenceLearningStore(profile: profile)
        let settings = SentenceLearningSettings(defaults: defaults, store: store, allowsRecording: { true })
        await settings.start()
        let original = UserLexiconEntry(text: "Zornax", reading: "zornax", index: 1, count: 3)
        try await settings.editEntry(old: nil, new: original)
        #expect(settings.modelForInput != nil)
        #expect(settings.entries == [original])
        let updated = UserLexiconEntry(text: "Talvexa", reading: "talvexa", index: 1, count: 8)
        try await settings.editEntry(old: original, new: updated)
        #expect(try await store.load().entries == [updated])
        do {
            try await settings.editEntry(old: original, new: nil)
            Issue.record("A stale entry must not remove a newer row")
        } catch {}
        #expect(settings.entries == [updated])
        try await settings.editEntry(old: updated, new: nil)
        #expect(settings.entries.isEmpty)
        #expect(try await store.load().entries.isEmpty)
    }

    @Test func confirmedCandidatesLearnByDefaultAndDeleteAllInvalidatesPendingWork() async throws {
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
        defaults.set(false, forKey: "sentenceLearning.independentlyEnabled")
        defaults.set(true, forKey: "sentenceHistory.enabled")
        let memory = ApplicationMemorySettings(defaults: defaults,
            store: ApplicationMemoryStore(url: directory.appending(path: "memory.json")),
            allowsRecording: { !secure.enabled })
        let settings = SentenceLearningSettings(defaults: defaults, store: store,
            retiredHistory: InputHistoryStore(url: archive), allowsRecording: { !secure.enabled })
        func inputSnapshot() -> ApplicationMemorySnapshot {
            memory.snapshot(sentenceModel: settings.modelForInput)
        }

        #expect(defaults.object(forKey: "sentenceHistory.enabled") == nil)
        #expect(defaults.object(forKey: "sentenceLearning.independentlyEnabled") == nil)
        await memory.start()
        await settings.start()
        #expect(settings.hasRetiredHistory)
        #expect(try Data(contentsOf: archive) == oldBytes)
        #expect(!memory.usesVocabulary)
        #expect(settings.canRecord)
        #expect(!settings.canClearAll)

        let generation = settings.generation
        for reason in [CommitReason.literal, .passthrough, .automaticConfirmation, .aiCompletion, .focusChange] {
            settings.record(confirmation("Skipvax", reason: reason), expectedGeneration: generation)
        }
        let prefix = InputCandidate(text: "Prefixvax", language: .english, score: 1, consumedInputCount: 9)
        settings.record(InputCommit(input: "prefixvax", candidate: prefix, reason: .explicitSelection,
                                    remainingInput: "pending"), expectedGeneration: generation)
        secure.enabled = true
        settings.record(confirmation("Securevax"), expectedGeneration: generation)
        secure.enabled = false

        var session = InputSession(engine: CandidateEngine(providers: [SplitProvider()]))
        session.configure(languages: [.english], compositionLearningEnabled: true)
        session.append("zornaxquivora")
        let first = try #require(session.candidates.first { $0.text == "Zornax" })
        let firstCommit = session.commitResult(first, reason: .explicitSelection)
        settings.record(session.recordSuccessfulCommit(firstCommit) ?? firstCommit, expectedGeneration: generation)
        await settings.flush()
        #expect(try await store.load().model == nil)

        // Failed writes can be retried without dropping the accepted submission.
        try oldBytes.write(to: profile)
        let last = try #require(session.candidates.first { $0.text == "Quivora" })
        let lastCommit = session.commitResult(last, reason: .defaultAcceptance)
        settings.record(session.recordSuccessfulCommit(lastCommit) ?? lastCommit, expectedGeneration: generation)
        #expect(settings.canClearAll)
        await settings.flush()
        #expect(settings.canRetry && !settings.canRecord)
        try FileManager.default.removeItem(at: profile)
        settings.retry()
        await settings.flush()
        #expect(!settings.canRetry && settings.errorMessage == nil)
        let loaded = try await store.load()
        #expect(loaded.entries.map(\.text) == ["ZornaxQuivora"])
        #expect(loaded.entries.allSatisfy { $0.count == 1 })
        let engine = CandidateEngine()
        #expect(engine.candidates(for: "zornaxquivora", languages: [.english],
            applicationMemory: inputSnapshot()).contains { $0.text == "ZornaxQuivora" })
        #expect(inputSnapshot().vocabulary.isEmpty)

        secure.enabled = true
        #expect(!settings.canRecord)
        #expect(inputSnapshot().sentenceModel == nil)
        secure.enabled = false
        memory.vocabularyEnabled = true
        memory.recordVocabulary(confirmation("Quivora"))
        settings.record(confirmation("Vexora"), expectedGeneration: generation)
        settings.clear()
        #expect(inputSnapshot().sentenceModel == nil)
        #expect(inputSnapshot().vocabulary.count == 1)
        await settings.flush()
        settings.record(confirmation("Stalevax"), expectedGeneration: generation)
        await settings.flush()
        #expect(try await store.load().model == nil)
        #expect(settings.entries.isEmpty)
        #expect(settings.canRecord)
        settings.record(confirmation("Freshvax"), expectedGeneration: settings.generation)
        await settings.flush()
        #expect(settings.entries.map(\.text) == ["Freshvax"])
        await memory.flush()
        #expect(try Data(contentsOf: archive) == oldBytes)
        settings.deleteRetiredHistory()
        await settings.flush()
        #expect(!FileManager.default.fileExists(atPath: archive.path))
    }
}
