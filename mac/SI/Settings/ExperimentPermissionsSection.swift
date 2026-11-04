import SwiftUI

struct ExperimentPermissionsSection: View {
    var permissions: ExperimentPermissions = .shared

    var body: some View {
        Section {
            LabeledContent("Accessibility") {
                Text(L10n.text(permissions.accessibilityGranted ? "Allowed" : "Not allowed"))
                    .foregroundStyle(.secondary)
                Button("Request Accessibility…") { permissions.requestAccessibility() }
            }
            LabeledContent("Screen Recording") {
                Text(L10n.text(permissions.screenRecordingGranted ? "Allowed" : "Not allowed"))
                    .foregroundStyle(.secondary)
                Button("Request Screen Recording…") { permissions.requestScreenRecording() }
            }
            Button("Refresh Permission Status") { permissions.refresh() }
        } header: {
            Text("Experimental Permissions")
        } footer: {
            Text("Request Accessibility and Screen Recording separately for future input-control experiments. Granting permission does not change input behavior or enable Personal Learning or Input History.")
            Text("These permission actions do not inspect controls or capture images. macOS may require restarting SI after authorization; do not launch a second copy.")
        }
        .task {
            while !Task.isCancelled {
                permissions.refresh()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }
}
