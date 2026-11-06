import Foundation
import Testing
import SICore
import SIStorage
@testable import SISettings

@MainActor
struct SentenceHistorySettingsTests {
    @Test func sentenceConsentIsIndependentAndExportPreservesOnlyCompleteText() async throws {
        let suite = "si-sentence-history-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appending(path: suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let url = directory.appending(path: "sentences.sqlite3")
        let sentenceStore = InputHistoryStore(url: url, kind: .sentences)
        let submissionStore = InputHistoryStore(url: directory.appending(path: "history.sqlite3"))
        let submissions = InputHistorySettings(defaults: defaults, store: submissionStore, allowsRecording: { true })
        var secure = false
        let sentences = InputHistorySettings(defaults: defaults, store: sentenceStore, kind: .sentences,
                                             allowsRecording: { !secure })
        await submissions.start()
        await sentences.start()
        submissions.enabled = true
        submissions.record(InputCommit(input: "nihao", candidate: nil, reason: .literal))
        let app = "org.example.fixture"
        let text = "你好，世界！👩‍💻 "
        sentences.setSentenceCapture(true, in: app)
        #expect(!sentences.enabled)
        sentences.recordSentence(text, in: app, expectedGeneration: sentences.generation)
        sentences.enabled = true
        let stale = sentences.generation
        sentences.setSentenceCapture(false, in: app)
        sentences.setSentenceCapture(true, in: app)
        sentences.recordSentence(text, in: app, expectedGeneration: stale)
        sentences.recordSentence(text, in: "org.example.other", expectedGeneration: sentences.generation)
        secure = true
        sentences.recordSentence(text, in: app, expectedGeneration: sentences.generation)
        secure = false
        sentences.recordSentence("一\n二", in: app, expectedGeneration: sentences.generation)
        sentences.recordSentence(text, in: app, expectedGeneration: sentences.generation)

        let destination = directory.appending(path: "sentences.jsonl")
        await sentences.export(to: destination)
        let raw = try String(contentsOf: destination, encoding: .utf8)
        let rows = try raw.split(separator: "\n").map {
            try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        #expect(rows.count == 3)
        #expect(rows.first?["format"] as? String == "si-sentence-history")
        let entry = try #require(rows.dropFirst().first)
        #expect((entry["output"] as? String)?.utf8.elementsEqual(text.utf8) == true)
        #expect(Set(entry.keys) == ["type", "sequence", "id", "created_at_unix", "output"])
        #expect(rows.last?["record_count"] as? Int == 1)
        await #expect(throws: InputHistoryStore.StoreError.unsupportedVersion) {
            try await InputHistoryStore(url: url).prepare()
        }

        sentences.clear()
        await sentences.flush()
        await submissions.flush()
        #expect(try await sentenceStore.page().entries.isEmpty)
        #expect(try await submissionStore.page().entries.count == 1)
    }
}
