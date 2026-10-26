import SwiftUI

struct UpdateSettingsSection: View {
    let updater: AppUpdater

    var body: some View {
        Section {
            LabeledContent("Version", value: version)
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
            if let message = updater.availabilityMessage {
                Text(message).foregroundStyle(.secondary)
            }
        } header: {
            Text("Software Updates")
        } footer: {
            Text("Checks run only when requested. Save your work and finish composing before installing; SI will restart. If typing does not resume, log out and back in. No typing or personal phrases are sent.")
        }
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? L10n.text("Unknown")) (\(info?["CFBundleVersion"] as? String ?? L10n.text("Unknown")))"
    }
}
