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
final class ApplicationMemorySettings {
    static let shared = ApplicationMemorySettings(defaults: SettingsDefaults.shared)
    private static let vocabularyKey = "applicationMemory.vocabularyEnabled"
    private static let historyKey = "applicationMemory.historyEnabled"
    private static let vocabularyExclusionsKey = "applicationMemory.vocabularyExclusions"
    private static let historyExclusionsKey = "applicationMemory.historyExclusions"

    var vocabularyEnabled: Bool {
        didSet {
            defaults.set(vocabularyEnabled, forKey: Self.vocabularyKey)
            if vocabularyEnabled != oldValue { invalidateConsent() }
        }
    }
    var historyEnabled: Bool {
        didSet {
            defaults.set(historyEnabled, forKey: Self.historyKey)
            if historyEnabled != oldValue { invalidateConsent() }
        }
    }
    private(set) var vocabularyExclusions: Set<String>
    private(set) var historyExclusions: Set<String>
    private(set) var memory = ApplicationMemory()
    private(set) var generation: UInt64 = 0
    private(set) var isLoading = true
    private(set) var isSaving = false
    private(set) var errorMessage: String?
    private(set) var hasLegacyLearningData = false
    private(set) var isRemovingLegacyData = false
    private(set) var legacyRemovalError: String?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let store: ApplicationMemoryStore?
    @ObservationIgnored private let allowsRecording: @MainActor () -> Bool
    @ObservationIgnored private var snapshots: [String: ApplicationMemorySnapshot] = [:]
    @ObservationIgnored private var pendingWrite: Task<Void, Never>?
    @ObservationIgnored private var maintenance: Task<Void, Never>?
    @ObservationIgnored private var legacyRemoval: Task<Void, Never>?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var loadSucceeded = false

    var applicationIDs: [String] {
        Set(memory.applicationIDs).union(vocabularyExclusions).union(historyExclusions).sorted()
    }
    var canRetrySaving: Bool { loadSucceeded && errorMessage != nil }

    init(defaults: UserDefaults = .standard, store: ApplicationMemoryStore? = nil, isPreview: Bool = false,
         allowsRecording: @escaping @MainActor () -> Bool = { !IsSecureEventInputEnabled() }) {
        self.defaults = defaults
        self.allowsRecording = allowsRecording
        vocabularyEnabled = !isPreview && defaults.bool(forKey: Self.vocabularyKey)
        historyEnabled = !isPreview && defaults.bool(forKey: Self.historyKey)
        vocabularyExclusions = Set(defaults.stringArray(forKey: Self.vocabularyExclusionsKey) ?? [])
        historyExclusions = Set(defaults.stringArray(forKey: Self.historyExclusionsKey) ?? [])
        self.store = isPreview ? nil : store ?? ApplicationMemoryStore(
            url: URL.applicationSupportDirectory.appending(path: "SI/Personalization/application-memory-v1.json"),
            legacyLearningURL: URL.applicationSupportDirectory.appending(path: "SI/Personalization/preferences-v1.json")
        )
        if isPreview { isLoading = false; loadSucceeded = true }
    }

    func start() async {
        guard !hasStarted, let store else { return }
        hasStarted = true
        hasLegacyLearningData = await store.hasLegacyLearningData()
        do {
            memory = try await store.load()
            loadSucceeded = true
        } catch {
            errorMessage = L10n.text("App vocabulary and history could not be opened. Recording and suggestions are paused. Clear all app data to start again.")
        }
        isLoading = false
        invalidateConsent()
        maintenance = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(86_400)) } catch { return }
                guard let self else { return }
                self.prune()
            }
        }
    }

    func usesVocabulary(in applicationID: String) -> Bool {
        vocabularyEnabled && loadSucceeded && allowsRecording() && !vocabularyExclusions.contains(applicationID)
    }

    func usesHistory(in applicationID: String) -> Bool {
        historyEnabled && loadSucceeded && allowsRecording() && !historyExclusions.contains(applicationID)
    }

    func snapshot(for applicationID: String) -> ApplicationMemorySnapshot {
        // Observe consent invalidation even when a cached snapshot is returned to SwiftUI.
        _ = generation
        guard loadSucceeded, allowsRecording() else { return .empty }
        if let snapshot = snapshots[applicationID] { return snapshot }
        let snapshot = memory.snapshot(applicationID: applicationID, vocabularyEnabled: usesVocabulary(in: applicationID),
                                       historyEnabled: usesHistory(in: applicationID))
        snapshots[applicationID] = snapshot
        return snapshot
    }

    func recordVocabulary(_ commit: InputCommit, applicationID: String) {
        guard usesVocabulary(in: applicationID), memory.recordVocabulary(commit, applicationID: applicationID) else { return }
        snapshots.removeAll()
        scheduleSave()
    }

    func recordHistory(_ entry: ApplicationHistoryEntry) {
        guard usesHistory(in: entry.applicationID), memory.recordHistory(entry) else { return }
        snapshots.removeAll()
        scheduleSave()
    }

    func setVocabularyAllowed(_ allowed: Bool, applicationID: String) {
        if allowed { vocabularyExclusions.remove(applicationID) } else { vocabularyExclusions.insert(applicationID) }
        defaults.set(vocabularyExclusions.sorted(), forKey: Self.vocabularyExclusionsKey)
        invalidateConsent()
    }

    func setHistoryAllowed(_ allowed: Bool, applicationID: String) {
        if allowed { historyExclusions.remove(applicationID) } else { historyExclusions.insert(applicationID) }
        defaults.set(historyExclusions.sorted(), forKey: Self.historyExclusionsKey)
        invalidateConsent()
    }

    func removeVocabulary(id: String) {
        guard loadSucceeded else { return }
        memory.removeVocabulary(id: id)
        invalidateConsent()
        scheduleSave(immediate: true)
    }

    func removeHistory(id: String) {
        guard loadSucceeded else { return }
        memory.removeHistory(id: id)
        invalidateConsent()
        scheduleSave(immediate: true)
    }

    func clearVocabulary(applicationID: String? = nil) {
        guard loadSucceeded else { return }
        memory.clearVocabulary(applicationID: applicationID)
        invalidateConsent()
        scheduleSave(immediate: true)
    }

    func clearHistory(applicationID: String? = nil) {
        guard loadSucceeded else { return }
        memory.clearHistory(applicationID: applicationID)
        invalidateConsent()
        scheduleSave(immediate: true)
    }

    func clearAll() {
        guard !isLoading else { return }
        pendingWrite?.cancel()
        memory = ApplicationMemory()
        invalidateConsent()
        revision += 1
        let currentRevision = revision
        isSaving = true
        // Pause until deletion succeeds, including when recovering an unreadable archive.
        loadSucceeded = false
        pendingWrite = Task {
            do {
                try await store?.erase(revision: currentRevision)
                guard revision == currentRevision else { return }
                loadSucceeded = true
                errorMessage = nil
                isSaving = false
            } catch {
                guard revision == currentRevision else { return }
                errorMessage = L10n.text("App data could not be cleared. Recording and suggestions remain paused; retry clearing.")
                isSaving = false
            }
        }
    }

    func clearLegacyLearningData() {
        guard hasLegacyLearningData, !isRemovingLegacyData, let store else { return }
        isRemovingLegacyData = true
        legacyRemovalError = nil
        legacyRemoval = Task {
            do {
                try await store.eraseLegacyLearningData()
                hasLegacyLearningData = false
                defaults.removeObject(forKey: "personalization.enabled")
                defaults.removeObject(forKey: "personalization.contextEnabled")
            } catch {
                legacyRemovalError = L10n.text("Old shared learning data could not be deleted. Please retry.")
            }
            isRemovingLegacyData = false
        }
    }

    func flush() async {
        await legacyRemoval?.value
        await pendingWrite?.value
        guard loadSucceeded else { return }
        scheduleSave(immediate: true)
        await pendingWrite?.value
    }

    private func invalidateConsent() {
        generation &+= 1
        snapshots.removeAll()
    }

    private func prune() {
        guard loadSucceeded else { return }
        let previous = memory
        memory.prune()
        if previous != memory {
            invalidateConsent()
            scheduleSave(immediate: true)
        }
    }

    private func scheduleSave(immediate: Bool = false) {
        pendingWrite?.cancel()
        revision += 1
        let currentRevision = revision
        let snapshot = memory
        isSaving = true
        pendingWrite = Task {
            if !immediate {
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            do {
                try await store?.save(snapshot, revision: currentRevision)
                guard revision == currentRevision else { return }
                errorMessage = nil
                isSaving = false
            } catch {
                guard revision == currentRevision else { return }
                errorMessage = L10n.text("App vocabulary or history changes could not be saved. They remain in memory; retry saving before quitting.")
                isSaving = false
            }
        }
    }
}
