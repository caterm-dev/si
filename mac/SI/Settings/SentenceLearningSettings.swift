import Foundation
import Observation
#if SWIFT_PACKAGE
import SICore
import SILocalization
import SIStorage
#endif

@MainActor
@Observable
final class SentenceLearningSettings {
    private static let enabledKey = "sentenceLearning.enabled"
    private static let maximumBatchSize = 32

    var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: Self.enabledKey)
            if enabled != oldValue { generation &+= 1 }
        }
    }
    private(set) var generation: UInt64 = 0
    private(set) var isLoading: Bool
    private(set) var isClearing = false
    private(set) var errorMessage: String?
    private(set) var model: SentenceLearningModel?
    private(set) var hasRetiredHistory = false
    private(set) var isDeletingRetiredHistory = false
    private(set) var retiredHistoryError: String?
    private(set) var canRetry = false

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let store: SentenceLearningStore?
    @ObservationIgnored private let retiredHistory: InputHistoryStore?
    @ObservationIgnored private var queued: [String] = []
    @ObservationIgnored private var failed: Batch?
    @ObservationIgnored private var delay: Task<Void, Never>?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var deletion: Task<Void, Never>?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var storageGeneration: UInt64 = 0

    private struct Batch {
        let id = UUID()
        let sentences: [String]
    }

    init(defaults: UserDefaults, store: SentenceLearningStore? = nil, retiredHistory: InputHistoryStore? = nil) {
        self.defaults = defaults
        self.store = store
        self.retiredHistory = retiredHistory
        enabled = store != nil && (defaults.object(forKey: Self.enabledKey) as? Bool ?? true)
        isLoading = store != nil
        if store != nil {
            defaults.removeObject(forKey: "sentenceHistory.enabled")
            defaults.removeObject(forKey: "sentenceHistory.applications")
        }
    }

    var canCapture: Bool {
        enabled && !isLoading && !isClearing && errorMessage == nil && queued.count < Self.maximumBatchSize
    }

    var hasDataOrError: Bool { model != nil || worker != nil || delay != nil || errorMessage != nil }

    func start() async {
        guard !started, let store else { return }
        started = true
        hasRetiredHistory = await retiredHistory?.hasDatabaseFiles() ?? false
        do { model = try await store.load() }
        catch {
            errorMessage = L10n.text("Sentence learning data could not be opened. Clear all learning data to start again.")
        }
        isLoading = false
    }

    func record(_ text: String, expectedGeneration: UInt64) {
        guard generation == expectedGeneration, canCapture, SentenceSnapshot.accepts(text) else { return }
        queued.append(text)
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
        guard let store, !isLoading, !isClearing else { return }
        generation &+= 1
        storageGeneration &+= 1
        delay?.cancel()
        delay = nil
        queued.removeAll()
        failed = nil
        canRetry = false
        model = nil
        isClearing = true
        let previous = worker
        worker = Task {
            await previous?.value
            do {
                try await store.clear()
                errorMessage = nil
            } catch {
                errorMessage = L10n.text("Sentence learning data could not be cleared. Please try clearing it again.")
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
                    batch = Batch(sentences: queued)
                    queued.removeAll()
                }
                do {
                    let updated = try await store.ingest(batch.sentences, batchID: batch.id)
                    guard epoch == storageGeneration else { return }
                    model = updated
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
            worker = nil
        }
    }
}
