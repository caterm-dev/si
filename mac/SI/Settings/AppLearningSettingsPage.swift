import SwiftUI

struct AppLearningSettingsPage: View {
    @Bindable var settings: AppLearningSettings = .shared
    @State private var clearAll = false
    @State private var deleting: String?
    @State private var confirmDelete = false

    var body: some View {
        SettingsGroup("App Learning") {
            Toggle("Enable App Learning", isOn: $settings.enabled)
            Text("Every 30 seconds, SI reads eligible foreground app text through Accessibility and saves a separate local vocabulary and word-gram model for that app. Button text is excluded. These models do not affect candidates yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if settings.enabled && !settings.permissionGranted {
                Text("Allow SI in macOS Accessibility settings, then refresh permission status here. No app text is read until permission is granted.")
                    .font(.callout)
                HStack {
                    Button("Open Accessibility Settings…") { ExperimentPermissions.shared.openAccessibilitySettings() }
                    Button("Refresh Permission Status") { settings.refreshPermission() }
                }
            }
            if let error = settings.errorMessage {
                Text(error).foregroundStyle(.red)
                Button("Retry App Learning") { settings.retry() }
            } else if settings.enabled && settings.permissionGranted {
                Text(settings.status).font(.callout).foregroundStyle(.secondary)
                if settings.isSampling { ProgressView().controlSize(.small).accessibilityLabel("Reading app text") }
                if let date = settings.lastSample { Text(date, style: .time).font(.caption).foregroundStyle(.secondary) }
            }
        }
        SettingsGroup("Saved App Data") {
            Text("Only derived vocabulary, word grams and app metadata are saved. Raw AX snapshots and source paragraphs are not saved. Data stays on this Mac until you delete it; turning off App Learning stops sampling and keeps saved models.")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(settings.profiles) { profile in
                HStack {
                    VStack(alignment: .leading) {
                        Text(profile.bundle)
                        Text(L10n.format("%ld words · %ld word grams", profile.words, profile.grams))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Delete", role: .destructive) { deleting = profile.bundle; confirmDelete = true }
                        .accessibilityLabel(L10n.format("Delete App Learning for %@", profile.bundle))
                        .disabled(settings.isClearing)
                }
            }
            Button("Clear All App Learning Data…", role: .destructive) { clearAll = true }
                .disabled(settings.isClearing)
        }
        .confirmationDialog("Clear all App Learning data?", isPresented: $clearAll) {
            Button("Delete All", role: .destructive) { Task { await settings.clear() } }
        } message: {
            Text("This deletes app vocabulary, word grams and metadata. Other personal data is kept.")
        }
        .confirmationDialog("Delete this app’s learning data?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                let bundle = deleting
                deleting = nil
                if let bundle { Task { await settings.clear(bundle: bundle) } }
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        }
        .task {
            await settings.load()
            while !Task.isCancelled {
                settings.refreshPermission()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }
}
