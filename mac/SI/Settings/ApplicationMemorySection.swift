import SwiftUI

struct ApplicationMemorySection: View {
    @Bindable var settings: ApplicationMemorySettings
    @State private var showsManager = false
    @State private var showsClearConfirmation = false
    @State private var showsLegacyClearConfirmation = false

    var body: some View {
        Section {
            Toggle("Learn vocabulary separately for each app", isOn: $settings.vocabularyEnabled)
                .disabled(settings.isLoading)
            Text("Counts confirmed candidate uses for each app. Accepting the first candidate only updates its use count; every three choices of a later candidate add one ranking point, with decay and a 32-point cap. Turning this off returns to base ranking.")
                .font(.callout).foregroundStyle(.secondary)
            if settings.isLoading {
                ProgressView("Opening app vocabulary…")
            } else {
                Text(L10n.format("Vocabulary entries: %ld", settings.memory.vocabulary.count))
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Manage App Data…") { showsManager = true }
                    Button("Clear All App Data…", role: .destructive) { showsClearConfirmation = true }
                        .disabled(settings.memory.applicationIDs.isEmpty && settings.errorMessage == nil)
                }
                if settings.isSaving { ProgressView("Saving app data…").controlSize(.small) }
            }
            if let error = settings.errorMessage {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
                if settings.canRetrySaving { Button("Retry Saving") { Task { await settings.flush() } } }
            }
            if settings.hasLegacyLearningData {
                Text("Older shared learning data is no longer used. You can delete it without affecting app vocabulary or personal phrases.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Delete Old Shared Learning Data…", role: .destructive) { showsLegacyClearConfirmation = true }
                    .disabled(settings.isRemovingLegacyData)
                if settings.isRemovingLegacyData { ProgressView("Deleting old shared data…").controlSize(.small) }
            }
            if let error = settings.legacyRemovalError { Text(error).foregroundStyle(.red) }
        } header: {
            Text("App Vocabulary")
        } footer: {
            Text("App vocabulary is off by default and stays on this Mac. Entries expire after 90 days without use (5,000 entries total). No document or clipboard content is read. You can pause vocabulary learning for an individual app in Manage App Data.")
        }
        .sheet(isPresented: $showsManager) { ApplicationMemoryView(settings: settings) }
        .confirmationDialog("Clear all app vocabulary?", isPresented: $showsClearConfirmation) {
            Button("Clear All App Data", role: .destructive) { settings.clearAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes every app’s vocabulary on this Mac. Explicit personal phrases are kept.")
        }
        .confirmationDialog("Delete old shared learning data?", isPresented: $showsLegacyClearConfirmation) {
            Button("Delete Old Shared Learning Data", role: .destructive) { settings.clearLegacyLearningData() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes the retired Personal learning archive on this Mac. App vocabulary and explicit personal phrases are kept.")
        }
    }
}
