import Foundation
import Observation
import Carbon
#if SWIFT_PACKAGE
import SICore
import SIStorage
#endif

@MainActor
@Observable
final class PersonalizationSettings {
    static let shared = PersonalizationSettings(defaults: SettingsDefaults.shared)
    private static let enabledKey = "personalization.enabled"
    private static let contextKey = "personalization.contextEnabled"

    var contextEnabled: Bool {
        didSet {
            if store != nil { defaults.set(contextEnabled, forKey: Self.contextKey) }
            if oldValue != contextEnabled { contextGeneration &+= 1 }
        }
    }

    var isEnabled: Bool {
        didSet {
            if store != nil { defaults.set(isEnabled, forKey: Self.enabledKey) }
            if oldValue != isEnabled { contextGeneration &+= 1 }
        }
    }
    private(set) var isLoading = true
    private(set) var isSaving = false
    private(set) var errorMessage: String?
    private(set) var profile = LearningProfile()
    private(set) var contextGeneration: UInt64 = 0

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let store: LearningStore?
    @ObservationIgnored private let allowsLearning: @MainActor () -> Bool
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var pendingWrite: Task<Void, Never>?
    @ObservationIgnored private var maintenance: Task<Void, Never>?
    @ObservationIgnored private var loadSucceeded = false
    @ObservationIgnored private var hasStarted = false

    var rankingProfile: LearningProfile {
        isEnabled && loadSucceeded && allowsLearning() ? profile : LearningProfile()
    }

    var canRetrySaving: Bool { loadSucceeded && errorMessage != nil }
    var usesContext: Bool { isEnabled && contextEnabled && loadSucceeded && allowsLearning() }

    var entries: [LearnedPreference] { profile.entries }

    init(defaults: UserDefaults = .standard, store: LearningStore? = nil, isPreview: Bool = false,
         allowsLearning: @escaping @MainActor () -> Bool = { !IsSecureEventInputEnabled() }) {
        self.defaults = defaults
        self.allowsLearning = allowsLearning
        isEnabled = isPreview ? false : defaults.bool(forKey: Self.enabledKey)
        contextEnabled = isPreview ? false : defaults.bool(forKey: Self.contextKey)
        self.store = isPreview ? nil : store ?? LearningStore(
            url: URL.applicationSupportDirectory.appending(path: "SI/Personalization/preferences-v1.json")
        )
        if isPreview {
            isLoading = false
            loadSucceeded = true
        }
    }

    func start() async {
        guard !hasStarted, isLoading, let store else { return }
        hasStarted = true
        do {
            profile = try await store.load()
            loadSucceeded = true
        } catch {
            errorMessage = "Saved learning data could not be opened. Learning is paused. Clear saved data to start again."
        }
        isLoading = false
        // Retention applies to long-running input-method processes as well as restarts.
        maintenance = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(86_400)) } catch { return }
                guard let self else { return }
                self.pruneExpiredEntries()
            }
        }
    }

    func record(_ commit: InputCommit) {
        guard isEnabled, loadSucceeded, allowsLearning(), profile.record(commit, learnContext: contextEnabled) else { return }
        scheduleSave()
    }

    func remove(id: String) {
        guard loadSucceeded else { return }
        profile.remove(id: id)
        scheduleSave(immediate: true)
    }

    func clear() {
        guard !isLoading else { return }
        contextGeneration &+= 1
        pendingWrite?.cancel()
        profile.removeAll()
        revision += 1
        let currentRevision = revision
        isSaving = true
        pendingWrite = Task {
            do {
                try await store?.erase(revision: currentRevision)
                guard currentRevision == revision else { return }
                errorMessage = nil
                loadSucceeded = true
                isSaving = false
            } catch {
                guard currentRevision == revision else { return }
                errorMessage = "Saved learning data could not be cleared. Please retry."
                loadSucceeded = false
                isSaving = false
            }
        }
    }

    func flush() async {
        await pendingWrite?.value
        guard loadSucceeded else { return }
        scheduleSave(immediate: true)
        await pendingWrite?.value
    }

    private func pruneExpiredEntries() {
        guard loadSucceeded else { return }
        let count = profile.entries.count
        profile.prune()
        if profile.entries.count != count { scheduleSave(immediate: true) }
    }

    private func scheduleSave(immediate: Bool = false) {
        pendingWrite?.cancel()
        revision += 1
        let currentRevision = revision
        let snapshot = profile
        isSaving = true
        pendingWrite = Task {
            if !immediate {
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            do {
                try await store?.save(snapshot, revision: currentRevision)
                guard currentRevision == revision else { return }
                errorMessage = nil
                isSaving = false
            } catch {
                guard currentRevision == revision else { return }
                errorMessage = "Learning changes could not be saved. They remain in memory; retry saving before quitting."
                isSaving = false
            }
        }
    }
}
