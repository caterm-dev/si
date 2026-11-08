import SwiftUI

struct ExperimentPermissionsSection: View {
    var permissions: ExperimentPermissions = .shared

    var body: some View {
        SettingsGroup("System Access") {
            SettingsRow(
                title: Text("Accessibility"),
                detail: Text(L10n.text(permissions.accessibilityGranted ? "Allowed" : "Not allowed"))
            ) {
                Button("Open Settings…", action: permissions.openAccessibilitySettings)
                    .accessibilityLabel("Open Accessibility Settings…")
            }
            Divider()
            SettingsRow(
                title: Text("Screen Recording"),
                detail: Text(L10n.text(permissions.screenRecordingGranted ? "Allowed" : "Not allowed"))
            ) {
                Button("Open Settings…", action: permissions.openScreenRecordingSettings)
                    .accessibilityLabel("Open Screen Recording Settings…")
            }
            Divider()
            Button("Refresh Permission Status") { permissions.refresh() }
        }
        SettingsGroup("Granting Permissions") {
            VStack(alignment: .leading, spacing: 12) {
                Text("To grant either experimental permission, drag SI from the floating panel into the list in System Settings.")
                Text("Screen Recording allows window screenshots for manually requested AI completion. macOS may require restarting SI after authorization.")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .task {
            await refreshPermissionStatus()
        }
    }

    private func refreshPermissionStatus() async {
        while !Task.isCancelled {
            permissions.refresh()
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
        }
    }
}
