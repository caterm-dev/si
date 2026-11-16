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
    private static let enabledKey = "sentenceLearning.independentlyEnabled"
    private static let previousEnabledKey = "sentenceLearning.enabled"
    private static let maximumBatchSize = 32

    var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: Self.enabledKey)
            if enabled != oldValue {
                generation &+= 1
                captureStatus = nil
            }
        }
    }
    private(set) var generation: UInt64 = 0
    private(set) var isLoading: Bool
    private(set) var isClearing = false
    private(set) var errorMessage: String?
    private(set) var model: SentenceLearningModel?
    private(set) var recentSamples: [String] = []
    private(set) var entries: [UserLexiconEntry] = []
    private(set) var isEditing = false
    private(set) var hasRetiredHistory = false
    private(set) var isDeletingRetiredHistory = false
    private(set) var retiredHistoryError: String?
    private(set) var canRetry = false
    private(set) var captureStatus: CaptureStatus?

    enum CaptureStatus: Equatable {
        case skipped(SentenceSnapshot.CaptureFailure)
        case queued(SentenceSnapshot.Coverage)
        case saved(SentenceSnapshot.Coverage)

        var message: String {
            switch self {
            case .skipped(.unavailableText), .skipped(.incompleteRange):
                L10n.text("This app did not provide the complete input field.")
            case .skipped(.invalidText):
                L10n.text("The input field has no text to learn.")
            case .skipped(.markedText):
                L10n.text("Finish the marked text before pressing Return to learn the input field.")
            case .skipped(.staleClient):
                L10n.text("Input or learning settings changed during the text read.")
            case .queued(.fullField):
                L10n.text("Input field queued for learning.")
            case .saved(.fullField):
                L10n.text("Sentence model saved.")
            case .queued(.beforeCaret):
                L10n.text("Only the text before the caret could be read and was queued for learning.")
            case .saved(.beforeCaret):
                L10n.text("Sentence model saved using the text before the caret.")
            }
        }
    }

    @ObservationIgnored private let defaults: UserDefaults
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
        self.defaults = defaults
        self.store = store
        self.retiredHistory = retiredHistory
        self.allowsRecording = allowsRecording
        enabled = false
        isLoading = store != nil
        if store != nil {
            if let saved = defaults.object(forKey: Self.enabledKey) as? Bool {
                enabled = saved
            } else if let previous = defaults.object(forKey: Self.previousEnabledKey) as? Bool {
                // Preserve an explicit opt-in only when sentence learning was already active.
                enabled = previous && defaults.bool(forKey: ApplicationMemorySettings.vocabularyKey)
                defaults.set(enabled, forKey: Self.enabledKey)
            }
            defaults.removeObject(forKey: Self.previousEnabledKey)
            defaults.removeObject(forKey: "sentenceHistory.enabled")
            defaults.removeObject(forKey: "sentenceHistory.applications")
        }
    }

    var canCapture: Bool {
        enabled && !isLoading && !isClearing && !isEditing && errorMessage == nil
            && queued.count < Self.maximumBatchSize && allowsRecording()
    }

    var modelForInput: SentenceLearningModel? { enabled && model != nil && allowsRecording() ? model : nil }

    var hasDataOrError: Bool { model != nil || worker != nil || delay != nil || errorMessage != nil }

    func start() async {
        guard !started, let store else { return }
        started = true
        hasRetiredHistory = await retiredHistory?.hasDatabaseFiles() ?? false
        do {
            let snapshot = try await store.load()
            model = snapshot.model
            recentSamples = snapshot.recentSamples
            entries = snapshot.entries
        } catch {
            errorMessage = L10n.text("Sentence learning data could not be opened. Clear sentence learning data to start again.")
        }
        isLoading = false
    }

    var canEditEntries: Bool { !isLoading && !isClearing && !isEditing && errorMessage == nil }

    func editEntry(old: UserLexiconEntry?, new: UserLexiconEntry?) async throws {
        guard canEditEntries, let store else { throw SentenceLearningStore.StoreError.profile }
        isEditing = true
        defer { isEditing = false; entryEdit = nil }
        // Finish accepted captures first so an older batch cannot resurrect a deleted row.
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
                recentSamples = current.recentSamples
                entries = current.entries
            }
            throw error
        }
        model = snapshot.model
        recentSamples = snapshot.recentSamples
        entries = snapshot.entries
    }

    func record(_ text: String, coverage: SentenceSnapshot.Coverage = .fullField, expectedGeneration: UInt64) {
        guard generation == expectedGeneration, canCapture, SentenceSnapshot.accepts(text) else { return }
        queued.append(text)
        captureStatus = .queued(coverage)
        guard delay == nil, worker == nil else { return }
        delay = Task {
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            delay = nil
            drain()
        }
    }

    func reportCapture(_ status: CaptureStatus, expectedGeneration: UInt64) {
        guard enabled, generation == expectedGeneration else { return }
        captureStatus = status
    }

    func retry() {
        guard canRetry, !isClearing else { return }
        drain()
    }

    func clear() {
        guard let store, !isLoading, !isClearing, !isEditing else { return }
        generation &+= 1
        storageGeneration &+= 1
        delay?.cancel()
        delay = nil
        queued.removeAll()
        captureStatus = nil
        failed = nil
        canRetry = false
        model = nil
        recentSamples = []
        entries = []
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
                    batch = Batch(sentences: queued)
                    queued.removeAll()
                }
                do {
                    let updated = try await store.ingest(batch.sentences, batchID: batch.id)
                    guard epoch == storageGeneration else { return }
                    model = updated.model
                    recentSamples = updated.recentSamples
                    entries = updated.entries
                    failed = nil
                    canRetry = false
                    errorMessage = nil
                    if case .queued(let coverage) = captureStatus, queued.isEmpty, updated.model != nil {
                        captureStatus = .saved(coverage)
                    }
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
