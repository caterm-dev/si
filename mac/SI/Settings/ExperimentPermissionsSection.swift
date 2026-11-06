import SwiftUI

struct ExperimentPermissionsSection: View {
    var permissions: ExperimentPermissions = .shared

    var body: some View {
        Section {
            LabeledContent("Accessibility") {
                Text(L10n.text(permissions.accessibilityGranted ? "Allowed" : "Not allowed"))
                    .foregroundStyle(.secondary)
                Button("Open Accessibility Settings…", action: permissions.openAccessibilitySettings)
            }
            LabeledContent("Screen Recording") {
                Text(L10n.text(permissions.screenRecordingGranted ? "Allowed" : "Not allowed"))
                    .foregroundStyle(.secondary)
                Button("Open Screen Recording Settings…", action: permissions.openScreenRecordingSettings)
            }
            Button("Refresh Permission Status") { permissions.refresh() }
        } header: {
            Text("Experimental Permissions")
        } footer: {
            Text("To grant either experimental permission, drag SI from the floating panel into the list in System Settings.")
            Text("These permissions are for future experiments. macOS may require restarting SI after authorization.")
        }
        .task {
            while !Task.isCancelled {
                permissions.refresh()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }
}
