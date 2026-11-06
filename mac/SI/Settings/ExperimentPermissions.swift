import AppKit
import ApplicationServices
import CoreGraphics
import Observation
import PermissionFlow

@MainActor
@Observable
final class ExperimentPermissions {
    static let shared = ExperimentPermissions()

    @ObservationIgnored private lazy var flow = PermissionFlow.makeController(
        configuration: .init(
            requiredAppURLs: [Bundle.main.bundleURL],
            promptForAccessibilityTrust: false,
            localeIdentifier: Bundle.main.preferredLocalizations.first
        )
    )

    private(set) var accessibilityGranted = false
    private(set) var screenRecordingGranted = false

    func refresh() {
        accessibilityGranted = AXIsProcessTrusted()
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
    }

    func openAccessibilitySettings() {
        flow.authorize(pane: .accessibility)
    }

    func openScreenRecordingSettings() {
        flow.authorize(pane: .screenRecording)
    }
}
