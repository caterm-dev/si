import SwiftUI
import InputMethodKit
import OSLog

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var server: IMKServer?
    private var settingsWindow: NSWindow?
    private let logger = Logger(subsystem: "com.caterm.si", category: "Lifecycle")

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let identifier = Bundle.main.bundleIdentifier,
              let connection = Bundle.main.object(forInfoDictionaryKey: "InputMethodConnectionName") as? String,
              let server = IMKServer(name: connection, bundleIdentifier: identifier) else {
            logger.fault("Unable to initialize the SI input method server.")
            NSApplication.shared.terminate(nil)
            return
        }
        self.server = server
        if ProcessInfo.processInfo.arguments.contains("--settings") {
            showSettings()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 700),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false
            )
            window.title = "SI Settings"
            window.contentViewController = NSHostingController(rootView: SettingsView(settings: .shared))
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
