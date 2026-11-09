import Foundation
import Testing
import SICore
import SIStorage
@testable import SISettings

@MainActor
struct SentenceHistorySettingsTests {
    @Test func enabledSentencesCoverAllAppsAndRemoveRetiredAllowlist() async throws {
        let suite = "si-sentence-apps-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appending(path: suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        defaults.set(["org.example.old"], forKey: "sentenceHistory.applications")
        let store = InputHistoryStore(url: directory.appending(path: "sentences.sqlite3"), kind: .sentences)
        let history = InputHistorySettings(defaults: defaults, store: store, kind: .sentences,
                                           allowsRecording: { true })
        await history.start()
        #expect(!history.enabled)
        #expect(defaults.object(forKey: "sentenceHistory.applications") == nil)
        #expect(!history.canCaptureSentence(in: "org.example.old"))
        history.enabled = true
        #expect(!history.canCaptureSentence(in: nil))
        #expect(!history.canCaptureSentence(in: ""))
        for app in ["org.example.old", "org.example.new"] {
            #expect(history.canCaptureSentence(in: app))
            history.recordSentence("测试整句。", in: app, expectedGeneration: history.generation)
        }
        await history.flush()
        #expect(try await store.page().entries.count == 2)

        let restored = InputHistorySettings(defaults: defaults, store: store, kind: .sentences,
                                            allowsRecording: { true })
        await restored.start()
        #expect(restored.enabled)
        #expect(restored.canCaptureSentence(in: "org.example.another"))
        history.enabled = false
        history.recordSentence("关闭后不记录。", in: "org.example.new", expectedGeneration: history.generation)
        await history.flush()
        #expect(try await store.page().entries.count == 2)
    }

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
        #expect(!sentences.enabled)
        sentences.recordSentence(text, in: app, expectedGeneration: sentences.generation)
        sentences.enabled = true
        let stale = sentences.generation
        sentences.enabled = false
        sentences.enabled = true
        sentences.recordSentence(text, in: app, expectedGeneration: stale)
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
