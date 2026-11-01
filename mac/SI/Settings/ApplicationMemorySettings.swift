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

    var vocabularyEnabled: Bool {
        didSet {
            defaults.set(vocabularyEnabled, forKey: Self.vocabularyKey)
            if vocabularyEnabled != oldValue { invalidateConsent() }
        }
    }
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
    @ObservationIgnored private var sharedSnapshot: ApplicationMemorySnapshot?
    @ObservationIgnored private var pendingWrite: Task<Void, Never>?
    @ObservationIgnored private var legacyRemoval: Task<Void, Never>?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var loadSucceeded = false

    var canRetrySaving: Bool { loadSucceeded && errorMessage != nil }

    init(defaults: UserDefaults = .standard, store: ApplicationMemoryStore? = nil, isPreview: Bool = false,
         allowsRecording: @escaping @MainActor () -> Bool = { !IsSecureEventInputEnabled() }) {
        self.defaults = defaults
        self.allowsRecording = allowsRecording
        vocabularyEnabled = !isPreview && defaults.bool(forKey: Self.vocabularyKey)
        self.store = isPreview ? nil : store ?? ApplicationMemoryStore(
            url: URL.applicationSupportDirectory.appending(path: "SI/Personalization/application-memory-v1.json"),
            legacyLearningURL: URL.applicationSupportDirectory.appending(path: "SI/Personalization/preferences-v1.json")
        )
        if isPreview { isLoading = false; loadSucceeded = true }
        else {
            defaults.removeObject(forKey: "applicationMemory.vocabularyExclusions")
            defaults.removeObject(forKey: "applicationMemory.historyEnabled")
            defaults.removeObject(forKey: "applicationMemory.historyExclusions")
        }
    }

    func start() async {
        guard !hasStarted, let store else { return }
        hasStarted = true
        hasLegacyLearningData = await store.hasLegacyLearningData()
        do {
            memory = try await store.load()
            loadSucceeded = true
        } catch {
            errorMessage = L10n.text("Personal Learning data could not be opened. Recording and suggestions are paused. Clear all learning data to start again.")
        }
        isLoading = false
        invalidateConsent()
    }

    var usesVocabulary: Bool {
        vocabularyEnabled && loadSucceeded && allowsRecording()
    }

    func snapshot() -> ApplicationMemorySnapshot {
        // Observe consent invalidation even when a cached snapshot is returned to SwiftUI.
        _ = generation
        guard usesVocabulary else { return .empty }
        if let sharedSnapshot { return sharedSnapshot }
        let snapshot = memory.snapshot(vocabularyEnabled: true)
        sharedSnapshot = snapshot
        return snapshot
    }

    func recordVocabulary(_ commit: InputCommit) {
        guard usesVocabulary, memory.recordVocabulary(commit) else { return }
        sharedSnapshot = nil
        scheduleSave()
    }

    func removeVocabulary(id: String) {
        guard loadSucceeded else { return }
        memory.removeVocabulary(id: id)
        invalidateConsent()
        scheduleSave(immediate: true)
    }

    func clearVocabulary() {
        guard loadSucceeded else { return }
        memory.clearVocabulary()
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
                errorMessage = L10n.text("Learning data could not be cleared. Recording and suggestions remain paused; retry clearing.")
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
        sharedSnapshot = nil
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
                errorMessage = L10n.text("Personal Learning changes could not be saved. They remain in memory; retry saving before quitting.")
                isSaving = false
            }
        }
    }
}
