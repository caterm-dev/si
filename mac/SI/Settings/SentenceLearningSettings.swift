import Foundation
import Observation
import Carbon
#if SWIFT_PACKAGE
import SICore
import SILocalization
import SIStorage
#endif

@MainActor
@Observable
final class SentenceLearningSettings {
    static let shared = SentenceLearningSettings(
        defaults: SettingsDefaults.shared,
        store: SentenceLearningStore(profile: URL.applicationSupportDirectory.appending(path: "SI/Personalization/model.si-user")),
        retiredHistory: InputHistoryStore(url: URL.applicationSupportDirectory.appending(path: InputHistoryStore.retiredSentenceDatabasePath))
    )
    private(set) var generation: UInt64 = 0
    private(set) var isLoading: Bool
    private(set) var isClearing = false
    private(set) var errorMessage: String?
    private(set) var model: SentenceLearningModel?
    private(set) var entries: [UserLexiconEntry] = []
    private(set) var isEditing = false
    private(set) var hasRetiredHistory = false
    private(set) var isDeletingRetiredHistory = false
    private(set) var retiredHistoryError: String?
    private(set) var canRetry = false
    private var hasPendingLearning = false

    @ObservationIgnored private let store: SentenceLearningStore?
    @ObservationIgnored private let retiredHistory: InputHistoryStore?
    @ObservationIgnored private let allowsRecording: @MainActor () -> Bool
    @ObservationIgnored private var queued: [String] = []
    @ObservationIgnored private var failed: Batch?
    @ObservationIgnored private var delay: Task<Void, Never>?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var entryEdit: Task<SentenceLearningStore.Snapshot, Error>?
    @ObservationIgnored private var deletion: Task<Void, Never>?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var storageGeneration: UInt64 = 0

    private struct Batch {
        let id = UUID()
        let sentences: [String]
    }

    init(defaults: UserDefaults, store: SentenceLearningStore? = nil, retiredHistory: InputHistoryStore? = nil,
         allowsRecording: @escaping @MainActor () -> Bool = { !IsSecureEventInputEnabled() }) {
        self.store = store
        self.retiredHistory = retiredHistory
        self.allowsRecording = allowsRecording
        isLoading = store != nil
        if store != nil {
            defaults.removeObject(forKey: "sentenceLearning.independentlyEnabled")
            defaults.removeObject(forKey: "sentenceLearning.enabled")
            defaults.removeObject(forKey: "sentenceHistory.enabled")
            defaults.removeObject(forKey: "sentenceHistory.applications")
        }
    }

    var canRecord: Bool {
        store != nil && !isLoading && !isClearing && !isEditing && errorMessage == nil
            && queued.count < SentenceLearningStore.maximumBatchSize && allowsRecording()
    }

    var modelForInput: SentenceLearningModel? { allowsRecording() ? model : nil }

    var canClearAll: Bool {
        store != nil && !isLoading && !isClearing && !isEditing
            && (model != nil || hasPendingLearning || errorMessage != nil)
    }

    func start() async {
        guard !started, let store else { return }
        started = true
        hasRetiredHistory = await retiredHistory?.hasDatabaseFiles() ?? false
        do {
            let snapshot = try await store.load()
            model = snapshot.model
            entries = snapshot.entries
        } catch {
            errorMessage = L10n.text("Personal phrases could not be opened. Delete all phrases to start again.")
        }
        isLoading = false
    }

    var canEditEntries: Bool { !isLoading && !isClearing && !isEditing && errorMessage == nil }

    func editEntry(old: UserLexiconEntry?, new: UserLexiconEntry?) async throws {
        guard canEditEntries, let store else { throw SentenceLearningStore.StoreError.profile }
        isEditing = true
        defer { isEditing = false; entryEdit = nil }
        // Finish queued learning first so an older batch cannot resurrect a deleted row.
        delay?.cancel()
        delay = nil
        drain()
        let previous = worker
        let task = Task {
            await previous?.value
            guard errorMessage == nil else { throw SentenceLearningStore.StoreError.profile }
            return try await store.edit(old: old, new: new)
        }
        entryEdit = task
        let snapshot: SentenceLearningStore.Snapshot
        do {
            snapshot = try await task.value
        } catch {
            // A concurrent profile writer may have changed the row. Refresh the editor's
            // source without hiding the failed operation or pending learning errors.
            if let current = try? await store.load() {
                model = current.model
                entries = current.entries
            }
            throw error
        }
        model = snapshot.model
        entries = snapshot.entries
    }

    func recordReturnField(_ text: String, expectedGeneration: UInt64) {
        guard generation == expectedGeneration, canRecord,
              (1...SentenceLearningStore.maximumBatchBytes).contains(text.utf8.count) else { return }
        queued.append(text)
        hasPendingLearning = true
        guard delay == nil, worker == nil else { return }
        delay = Task {
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            delay = nil
            drain()
        }
    }

    func retry() {
        guard canRetry, !isClearing else { return }
        drain()
    }

    func clear() {
        guard canClearAll, let store else { return }
        generation &+= 1
        storageGeneration &+= 1
        delay?.cancel()
        delay = nil
        queued.removeAll()
        hasPendingLearning = false
        failed = nil
        canRetry = false
        model = nil
        entries = []
        isClearing = true
        let previous = worker
        worker = Task {
            await previous?.value
            do {
                try await store.clear()
                errorMessage = nil
            } catch {
                errorMessage = L10n.text("Personal phrases could not be deleted. Please try again.")
            }
            isClearing = false
            worker = nil
        }
    }

    func deleteRetiredHistory() {
        guard hasRetiredHistory, !isDeletingRetiredHistory, let retiredHistory else { return }
        isDeletingRetiredHistory = true
        retiredHistoryError = nil
        deletion = Task {
            do {
                try await retiredHistory.clear()
                hasRetiredHistory = false
            } catch {
                retiredHistoryError = L10n.text("Old Sentence History could not be deleted. Please retry.")
            }
            isDeletingRetiredHistory = false
        }
    }

    func flush() async {
        _ = try? await entryEdit?.value
        await deletion?.value
        delay?.cancel()
        delay = nil
        if errorMessage == nil { drain() }
        await worker?.value
    }

    private func drain() {
        guard worker == nil, let store, failed != nil || !queued.isEmpty else { return }
        let epoch = storageGeneration
        worker = Task {
            while epoch == storageGeneration, failed != nil || !queued.isEmpty {
                let batch: Batch
                if let failed { batch = failed }
                else {
                    var bytes = 0
                    let end = queued.firstIndex { text in
                        bytes += text.utf8.count
                        return bytes > SentenceLearningStore.maximumBatchBytes
                    } ?? queued.endIndex
                    batch = Batch(sentences: Array(queued[..<end]))
                    queued.removeFirst(end)
                }
                do {
                    let updated = try await store.ingest(batch.sentences, batchID: batch.id)
                    guard epoch == storageGeneration else { return }
                    model = updated.model
                    entries = updated.entries
                    failed = nil
                    canRetry = false
                    errorMessage = nil
                } catch {
                    guard epoch == storageGeneration else { return }
                    failed = batch
                    canRetry = true
                    errorMessage = L10n.text("Sentence learning could not be saved. Retry while SI is running to process the pending text.")
                    break
                }
            }
            hasPendingLearning = failed != nil || !queued.isEmpty
            worker = nil
        }
    }
}
