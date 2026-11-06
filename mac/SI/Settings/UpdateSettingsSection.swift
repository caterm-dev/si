import SwiftUI

struct UpdateSettingsSection: View {
    let updater: AppUpdater

    var body: some View {
        SettingsGroup("Software Updates") {
            SettingsRow(title: Text("Version"), detail: Text(version)) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
            if let message = updater.availabilityMessage {
                Text(message).foregroundStyle(.secondary)
            }
            Divider()
            Text("Checks run only when requested. Save your work and finish composing before installing; SI will restart. If typing does not resume, log out and back in. No typing or personal phrases are sent.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? L10n.text("Unknown")) (\(info?["CFBundleVersion"] as? String ?? L10n.text("Unknown")))"
    }
}
