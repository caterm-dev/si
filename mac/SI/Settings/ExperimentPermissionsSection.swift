import SwiftUI

struct ExperimentPermissionsSection: View {
    var permissions: ExperimentPermissions = .shared

    var body: some View {
        SettingsGroup("System Access") {
            SettingsRow(
                title: Text("Accessibility"),
                detail: Text(L10n.text(permissions.accessibilityGranted ? "Allowed" : "Not allowed"))
            ) {
                Button("Open Accessibility Settings…", action: permissions.openAccessibilitySettings)
            }
            Divider()
            SettingsRow(
                title: Text("Screen Recording"),
                detail: Text(L10n.text(permissions.screenRecordingGranted ? "Allowed" : "Not allowed"))
            ) {
                Button("Open Screen Recording Settings…", action: permissions.openScreenRecordingSettings)
            }
            Divider()
            Button("Refresh Permission Status") { permissions.refresh() }
        }
        SettingsGroup("Granting Permissions") {
            VStack(alignment: .leading, spacing: 12) {
                Text("To grant either experimental permission, drag SI from the floating panel into the list in System Settings.")
                Text("These permissions are for future experiments. macOS may require restarting SI after authorization.")
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
