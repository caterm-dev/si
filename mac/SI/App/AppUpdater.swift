import AppKit
import Combine
import Observation
import Sparkle

/// A process-lifetime updater, independent of composition and learning state.
@MainActor @Observable
final class AppUpdater {
    private(set) var canCheckForUpdates = false
    private(set) var availabilityMessage: String?
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var availability: AnyCancellable?

    func start() {
        guard controller == nil else { return }
        #if DEBUG
        availabilityMessage = "Updates are available in the installed Release app."
        #else
        let installedURL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Input Methods/SI.app", directoryHint: .isDirectory)
        guard Bundle.main.bundleURL.standardizedFileURL == installedURL.standardizedFileURL else {
            availabilityMessage = "Open the installed SI app to check for updates."
            return
        }
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil
        )
        self.controller = controller
        availability = controller.updater.publisher(for: \.canCheckForUpdates).sink { [weak self] value in
            Task { @MainActor [weak self] in
                guard let self, self.controller != nil else { return }
                self.canCheckForUpdates = value
            }
        }
        do {
            try controller.updater.start()
        } catch {
            availability?.cancel()
            self.controller = nil
            canCheckForUpdates = false
            availabilityMessage = "The updater could not start. Reinstall SI from the official download."
        }
        #endif
    }

    func checkForUpdates() {
        guard let controller, controller.updater.canCheckForUpdates else { return }
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
}
