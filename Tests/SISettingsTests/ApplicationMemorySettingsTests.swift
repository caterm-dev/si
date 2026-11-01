import Foundation
import Testing
import SICore
import SIStorage
@testable import SISettings

@MainActor
struct ApplicationMemorySettingsTests {
    @Test func retiredHistoryConsentAndAppExclusionsCannotEnableOrScopeLearning() async throws {
        let suite = "si-retired-history-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appending(path: suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let url = directory.appending(path: "memory.json")
        let store = ApplicationMemoryStore(url: url)
        defaults.set(true, forKey: "applicationMemory.historyEnabled")
        defaults.set(["org.example.editor"], forKey: "applicationMemory.historyExclusions")
        defaults.set(["org.example.editor"], forKey: "applicationMemory.vocabularyExclusions")
        let settings = ApplicationMemorySettings(defaults: defaults, store: store, allowsRecording: { true })
        #expect(defaults.object(forKey: "applicationMemory.historyEnabled") == nil)
        #expect(defaults.object(forKey: "applicationMemory.historyExclusions") == nil)
        #expect(defaults.object(forKey: "applicationMemory.vocabularyExclusions") == nil)
        await settings.start()
        #expect(!settings.vocabularyEnabled && !settings.usesVocabulary)
        settings.vocabularyEnabled = true
        let candidate = InputCandidate(text: "是", language: .simplifiedChinese, score: -7)
        settings.recordVocabulary(InputCommit(input: "shi", candidate: candidate, reason: .defaultAcceptance))
        #expect(settings.snapshot().vocabulary.first?.count == 1)
        await settings.flush()
        #expect(try await ApplicationMemoryStore(url: url).load().vocabulary.first?.count == 1)
        let restarted = ApplicationMemorySettings(defaults: defaults, store: ApplicationMemoryStore(url: url), allowsRecording: { true })
        await restarted.start()
        #expect(restarted.vocabularyEnabled && restarted.snapshot().vocabulary.first?.count == 1)
    }

    @Test func globalConsentSecureInputAndDeletionSuppressEveryLearningPath() async throws {
        let suite = "si-global-vocabulary-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appending(path: suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = ApplicationMemoryStore(url: directory.appending(path: "memory.json"))
        var secure = false
        let settings = ApplicationMemorySettings(defaults: defaults, store: store, allowsRecording: { !secure })
        await settings.start()
        settings.vocabularyEnabled = true
        let candidate = InputCandidate(text: "时刻", language: .simplifiedChinese, score: -500, lexicalTokenCount: 1)
        let correction = InputCommit(input: "shike", candidate: candidate, reason: .explicitSelection)
        settings.recordVocabulary(correction)
        let snapshot = settings.snapshot()
        #expect(snapshot.vocabulary.first?.correctionCount == 1 && snapshot.vocabulary.first?.lastSelected != nil)
        #expect(snapshot == settings.snapshot())
        var session = InputSession(candidateGeneration: .deferred)
        session.configure(languages: [.simplifiedChinese], learning: snapshot.learning, applicationMemory: snapshot)
        session.append("shike")
        let oldRequest = try #require(session.pendingCandidateRequest)
        let oldGeneration = settings.generation
        settings.vocabularyEnabled = false
        #expect(settings.generation != oldGeneration && settings.snapshot().vocabulary.isEmpty)
        settings.recordVocabulary(correction)
        #expect(settings.memory.vocabulary.first?.count == 1)
        let disabled = settings.snapshot()
        session.configure(languages: [.simplifiedChinese], learning: disabled.learning, applicationMemory: disabled)
        let accepted = session.accept(oldRequest.generate())
        #expect(!accepted)
        settings.vocabularyEnabled = true
        settings.recordVocabulary(correction)
        #expect(settings.memory.vocabulary.count == 1 && settings.memory.vocabulary.first?.count == 2)
        secure = true
        #expect(settings.snapshot().vocabulary.isEmpty)
        settings.recordVocabulary(correction)
        #expect(settings.memory.vocabulary.first?.count == 2)
        secure = false
        let id = try #require(settings.memory.vocabulary.first?.id)
        settings.removeVocabulary(id: id)
        #expect(settings.snapshot().vocabulary.isEmpty && settings.snapshot().learning.entries.isEmpty)
        await settings.flush()
        #expect(try await store.load().vocabulary.isEmpty)
        settings.vocabularyEnabled = false
        settings.recordVocabulary(correction)
        #expect(settings.snapshot().vocabulary.isEmpty && settings.memory.vocabulary.isEmpty)
    }
}
