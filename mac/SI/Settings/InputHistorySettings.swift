import Foundation
import Observation
import Carbon
#if SWIFT_PACKAGE
import SICore
import SIStorage
import SILocalization
#endif

@MainActor
@Observable
final class InputHistorySettings {
    static let shared = InputHistorySettings(defaults: SettingsDefaults.shared)
    static let sentences = InputHistorySettings(defaults: SettingsDefaults.shared, kind: .sentences)

    let kind: InputHistoryStore.Kind
    private let enabledKey: String
    var savesSentences: Bool { kind == .sentences }

    var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: enabledKey)
            if enabled != oldValue { generation &+= 1 }
        }
    }
    private(set) var generation: UInt64 = 0
    private(set) var isLoading = true
    private(set) var isClearing = false
    private(set) var isReading = false
    private(set) var isExporting = false
    private(set) var exportNotice: String?
    private(set) var exportError: String?
    private(set) var entries: [InputHistoryEntry] = []
    private(set) var nextCursor: Int64?
    private(set) var errorMessage: String?
    private(set) var operationError: String?
    private(set) var pendingOperations = 0
    private(set) var pendingRetryCount = 0
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let store: InputHistoryStore?
    @ObservationIgnored private let allowsRecording: @MainActor () -> Bool
    @ObservationIgnored private var loadSucceeded = false
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var storageGeneration: UInt64 = 0
    @ObservationIgnored private var readGeneration: UInt64 = 0
    @ObservationIgnored private var pendingWrite: Task<Void, Never>?
    @ObservationIgnored private var failedEntries: [InputHistoryEntry] = []
    @ObservationIgnored private var previousCursors: [Int64?] = []
    @ObservationIgnored private var currentCursor: Int64?

    var canRecord: Bool { enabled && loadSucceeded && !isClearing && errorMessage == nil && allowsRecording() }
    var isSaving: Bool { pendingOperations > 0 }
    var canReopen: Bool { !isLoading && !loadSucceeded && !isClearing }
    var hasPreviousPage: Bool { !previousCursors.isEmpty }

    init(defaults: UserDefaults = .standard, store: InputHistoryStore? = nil, isPreview: Bool = false,
         kind: InputHistoryStore.Kind = .submissions,
         allowsRecording: @escaping @MainActor () -> Bool = { !IsSecureEventInputEnabled() }) {
        let enabledKey = kind == .sentences ? "sentenceHistory.enabled" : "inputHistory.enabled"
        self.kind = kind
        self.enabledKey = enabledKey
        self.defaults = defaults
        self.store = isPreview ? nil : store ?? InputHistoryStore(
            url: URL.applicationSupportDirectory.appending(path: kind.databasePath), kind: kind)
        self.allowsRecording = allowsRecording
        enabled = !isPreview && defaults.bool(forKey: enabledKey)
        if kind == .sentences && !isPreview {
            defaults.removeObject(forKey: "sentenceHistory.applications")
        }
        if isPreview { isLoading = false; loadSucceeded = true }
    }

    func canCaptureSentence(in application: String?) -> Bool {
        guard savesSentences, let application, !application.isEmpty else { return false }
        return canRecord
    }

    func start() async {
        guard !hasStarted, let store else { return }
        hasStarted = true
        do {
            try await store.prepare()
            loadSucceeded = true
            errorMessage = nil
        } catch {
            loadSucceeded = false
            errorMessage = L10n.text("Input history could not be opened. Recording is paused; reopen or clear history to try again. Existing data is kept.")
        }
        isLoading = false
    }

    func reopen() async {
        guard canReopen else { return }
        hasStarted = false
        isLoading = true
        await start()
    }

    func record(_ commit: InputCommit, suffix: String = "", expectedGeneration: UInt64? = nil, now: Date = .now) {
        guard !savesSentences, canRecord, expectedGeneration == nil || expectedGeneration == generation,
              !commit.input.isEmpty, !(commit.text + suffix).isEmpty else { return }
        enqueueEntry(InputHistoryEntry(commit: commit, suffix: suffix, now: now))
    }

    func recordSentence(_ text: String, in application: String?, expectedGeneration: UInt64, now: Date = .now) {
        guard expectedGeneration == generation, canCaptureSentence(in: application), SentenceSnapshot.accepts(text) else { return }
        // Reuse history paging and retry. Snapshot rows carry no spelling or candidate metadata.
        enqueueEntry(InputHistoryEntry(createdAt: now, input: "", text: text, language: nil, reason: .literal))
    }

    private func enqueueEntry(_ entry: InputHistoryEntry) {
        guard let store else { return }
        let epoch = storageGeneration
        enqueue {
            guard epoch == self.storageGeneration else { return }
            if !self.failedEntries.isEmpty {
                self.retainForRetry(entry)
                return
            }
            do { try await store.append([entry]) }
            catch {
                guard epoch == self.storageGeneration else { return }
                self.retainForRetry(entry)
            }
        }
    }

    func retrySaving() {
        guard !failedEntries.isEmpty, !isClearing, let store else { return }
        let epoch = storageGeneration
        enqueue {
            guard epoch == self.storageGeneration else { return }
            do {
                try await store.append(self.failedEntries)
                self.failedEntries.removeAll()
                self.pendingRetryCount = 0
                self.errorMessage = nil
            } catch {
                self.errorMessage = L10n.text("Input history could not be saved. Recording is paused. Retry saving before quitting; pending records are only in memory.")
            }
        }
    }

    func remove(id: UUID) {
        guard !isClearing, let store else { return }
        let epoch = storageGeneration
        enqueue {
            guard epoch == self.storageGeneration else { return }
            do {
                try await store.remove(id: id)
                self.failedEntries.removeAll { $0.id == id }
                self.pendingRetryCount = self.failedEntries.count
                if self.failedEntries.isEmpty && self.loadSucceeded { self.errorMessage = nil }
                self.entries.removeAll { $0.id == id }
                self.operationError = nil
                self.readGeneration &+= 1
                self.isReading = false
            } catch {
                self.operationError = L10n.text("The history entry could not be deleted. Please try deleting it again.")
            }
        }
    }

    func clear() {
        guard !isLoading, !isClearing, let store else { return }
        storageGeneration &+= 1
        generation &+= 1
        readGeneration &+= 1
        isClearing = true
        isReading = false
        failedEntries.removeAll()
        pendingRetryCount = 0
        enqueue {
            do {
                try await store.clear()
                self.failedEntries.removeAll()
                self.pendingRetryCount = 0
                self.entries.removeAll()
                self.nextCursor = nil
                self.currentCursor = nil
                self.previousCursors.removeAll()
                self.loadSucceeded = true
                self.errorMessage = nil
                self.operationError = nil
            } catch {
                self.loadSucceeded = false
                self.errorMessage = L10n.text("Input history could not be cleared. Recording is paused. Please try clearing it again.")
            }
            self.isClearing = false
        }
    }

    func export(to destination: URL) async {
        guard !isExporting, !isLoading, !isClearing, let store else { return }
        isExporting = true
        exportError = nil
        exportNotice = nil
        // Share the mutation queue so normal termination also waits for accepted exports.
        enqueue {
            defer { self.isExporting = false }
            guard self.loadSucceeded, self.failedEntries.isEmpty, !self.isClearing else {
                self.exportError = L10n.text("History could not be exported. Resolve pending save errors or wait for clearing to finish, then try again.")
                return
            }
            do {
                let count = try await store.export(to: destination)
                self.exportNotice = L10n.format("Exported %ld history records. SI has not sent the file anywhere.", count)
            } catch {
                self.exportError = L10n.text("History export failed. Existing history and any previous destination file are kept. Check the JSONL destination and history storage before retrying.")
            }
        }
        await pendingWrite?.value
    }

    func refresh(search: String = "") async {
        previousCursors.removeAll()
        await loadPage(before: nil, search: search)
    }

    func nextPage(search: String) async {
        guard let nextCursor, !isReading else { return }
        previousCursors.append(currentCursor)
        await loadPage(before: nextCursor, search: search)
    }

    func previousPage(search: String) async {
        guard !previousCursors.isEmpty, !isReading else { return }
        let cursor = previousCursors.removeLast()
        await loadPage(before: cursor, search: search)
    }

    func flush() async { await pendingWrite?.value }

    private func loadPage(before cursor: Int64?, search: String) async {
        guard !isClearing, let store else { return }
        readGeneration &+= 1
        let request = readGeneration
        isReading = true
        await pendingWrite?.value
        guard request == readGeneration, !isClearing else { return }
        do {
            let page = try await store.page(before: cursor, search: search)
            guard request == readGeneration else { return }
            entries = page.entries
            nextCursor = page.nextCursor
            currentCursor = cursor
            operationError = nil
        } catch {
            guard request == readGeneration else { return }
            loadSucceeded = false
            errorMessage = L10n.text("Input history could not be opened. Recording is paused; reopen or clear history to try again. Existing data is kept.")
        }
        isReading = false
    }

    private func retainForRetry(_ entry: InputHistoryEntry) {
        failedEntries.append(entry)
        pendingRetryCount = failedEntries.count
        errorMessage = L10n.text("Input history could not be saved. Recording is paused. Retry saving before quitting; pending records are only in memory.")
    }

    private func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        let previous = pendingWrite
        pendingOperations += 1
        pendingWrite = Task {
            await previous?.value
            await operation()
            pendingOperations -= 1
        }
    }
}
