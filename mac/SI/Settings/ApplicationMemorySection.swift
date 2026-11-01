import SwiftUI

struct ApplicationMemorySection: View {
    @Bindable var settings: ApplicationMemorySettings
    @State private var showsManager = false
    @State private var showsClearConfirmation = false
    @State private var showsLegacyClearConfirmation = false

    var body: some View {
        Section {
            Toggle("Enable Personal Learning", isOn: $settings.vocabularyEnabled)
                .disabled(settings.isLoading)
            Text("Shares learned vocabulary across apps. A deliberate choice of a later candidate becomes the first choice for the same spelling next time, unless a personal phrase is pinned. Frequency rewards remain capped at 32 points. Learning does not decay or expire; turning it off returns to base ranking.")
                .font(.callout).foregroundStyle(.secondary)
            if settings.isLoading {
                ProgressView("Opening learning data…")
            } else {
                Text(L10n.format("Learning entries: %ld", settings.memory.vocabulary.count))
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Manage Learning Data…") { showsManager = true }
                    Button("Clear All Learning Data…", role: .destructive) { showsClearConfirmation = true }
                        .disabled(settings.memory.vocabulary.isEmpty && settings.errorMessage == nil)
                }
                if settings.isSaving { ProgressView("Saving learning data…").controlSize(.small) }
            }
            if let error = settings.errorMessage {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
                if settings.canRetrySaving { Button("Retry Saving") { Task { await settings.flush() } } }
            }
            if settings.hasLegacyLearningData {
                Text("The legacy learning archive is no longer used. You can delete it without affecting Personal Learning or personal phrases.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Delete Old Shared Learning Data…", role: .destructive) { showsLegacyClearConfirmation = true }
                    .disabled(settings.isRemovingLegacyData)
                if settings.isRemovingLegacyData { ProgressView("Deleting old shared data…").controlSize(.small) }
            }
            if let error = settings.legacyRemovalError { Text(error).foregroundStyle(.red) }
        } header: {
            Text("Personal Learning")
        } footer: {
            Text("Personal Learning is off by default and stays on this Mac. It keeps up to 5,000 global entries; when full, the least recently used entries are removed. No document or clipboard content is read.")
        }
        .sheet(isPresented: $showsManager) { ApplicationMemoryView(settings: settings) }
        .confirmationDialog("Clear all learning data?", isPresented: $showsClearConfirmation) {
            Button("Clear All Learning Data", role: .destructive) { settings.clearAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes all learned vocabulary on this Mac. Explicit personal phrases are kept.")
        }
        .confirmationDialog("Delete old shared learning data?", isPresented: $showsLegacyClearConfirmation) {
            Button("Delete Old Shared Learning Data", role: .destructive) { settings.clearLegacyLearningData() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes the legacy learning archive on this Mac. Current Personal Learning data and explicit personal phrases are kept.")
        }
    }
}
