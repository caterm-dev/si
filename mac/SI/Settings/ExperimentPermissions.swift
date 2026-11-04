import AppKit
import ApplicationServices
import CoreGraphics
import Observation

@MainActor
@Observable
final class ExperimentPermissions {
    static let shared = ExperimentPermissions()

    private(set) var accessibilityGranted = false
    private(set) var screenRecordingGranted = false

    func refresh() {
        accessibilityGranted = AXIsProcessTrusted()
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
    }

    func requestAccessibility() {
        // The SDK exports kAXTrustedCheckOptionPrompt as a mutable C global.
        // Use its verified CFString value without introducing unsafe Swift isolation.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        accessibilityGranted = AXIsProcessTrustedWithOptions(options)
        if !accessibilityGranted { openPrivacyPane("Privacy_Accessibility") }
    }

    func requestScreenRecording() {
        screenRecordingGranted = CGRequestScreenCaptureAccess()
        if !screenRecordingGranted { openPrivacyPane("Privacy_ScreenCapture") }
    }

    private func openPrivacyPane(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}
