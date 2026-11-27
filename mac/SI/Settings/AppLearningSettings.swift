import ApplicationServices
import Foundation
import Observation
#if SWIFT_PACKAGE
import SIStorage
import SILocalization
#endif

@MainActor
@Observable
final class AppLearningSettings {
    static let shared = AppLearningSettings(defaults: SettingsDefaults.shared,
        store: AppLearningStore(root: URL.applicationSupportDirectory.appending(path: "SI/AppLearning")))
    var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            defaults.set(enabled, forKey: "appLearning.enabled")
            generation &+= 1
            refreshPermission()
            onConfigurationChanged?()
        }
    }
    private(set) var permissionGranted = false
    private(set) var generation: UInt64 = 0
    private(set) var profiles: [AppLearningStore.Profile] = []
    private(set) var errorMessage: String?
    private(set) var isClearing = false
    private(set) var isSampling = false
    private(set) var lastSample: Date?
    private(set) var status = L10n.text("Waiting for the next 30-second sample.")
    @ObservationIgnored let store: AppLearningStore
    @ObservationIgnored var onConfigurationChanged: (@MainActor () -> Void)?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let checkPermission: @MainActor () -> Bool

    init(defaults: UserDefaults, store: AppLearningStore,
         checkPermission: @escaping @MainActor () -> Bool = { AXIsProcessTrusted() }) {
        self.defaults = defaults
        self.store = store
        self.checkPermission = checkPermission
        enabled = defaults.bool(forKey: "appLearning.enabled")
        refreshPermission()
    }

    var canSample: Bool { enabled && permissionGranted && !isClearing && errorMessage == nil }

    func refreshPermission() { permissionGranted = checkPermission() }

    func load() async {
        let epoch = generation
        do {
            let loaded = try await store.profiles()
            if epoch == generation { profiles = loaded }
        }
        catch { failed() }
    }

    func sampling(_ value: Bool) { isSampling = value }

    func sampled(changed: Bool) async {
        lastSample = .now
        status = L10n.text(changed ? "App vocabulary and word grams saved." : "Unchanged text was not counted again.")
        await load()
    }

    func skipped() { status = L10n.text("No complete eligible AX snapshot was available. This sample was skipped.") }

    func failed() {
        errorMessage = L10n.text("App Learning is paused because data could not be saved. Retry or clear its data.")
    }

    func retry() {
        errorMessage = nil
        generation &+= 1
        onConfigurationChanged?()
        Task { await load() }
    }

    func clear(bundle: String? = nil) async {
        guard !isClearing else { return }
        isClearing = true
        generation &+= 1
        onConfigurationChanged?()
        defer { isClearing = false }
        do {
            try await store.clear(bundle: bundle)
            errorMessage = nil
            profiles = try await store.profiles()
        } catch { failed() }
    }
}
