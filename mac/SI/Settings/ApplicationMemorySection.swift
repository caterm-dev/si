import SwiftUI

struct ApplicationMemorySection: View {
    @Bindable var settings: ApplicationMemorySettings
    @State private var showsManager = false
    @State private var showsClearConfirmation = false

    var body: some View {
        Section {
            Toggle("Learn vocabulary separately for each app", isOn: $settings.vocabularyEnabled)
                .disabled(settings.isLoading)
            Text("Counts confirmed candidate choices, including the default accepted with Space. App vocabulary replaces shared learning while enabled; saved shared preferences are kept.")
                .font(.callout).foregroundStyle(.secondary)
            Toggle("Remember input history separately for each app", isOn: $settings.historyEnabled)
                .disabled(settings.isLoading)
            Text("Saves input units when an unmodified Return is passed to the app, including literal text. Earlier input can appear as an App History candidate; select it to complete. A Return used to finish composition does not end the history unit.")
                .font(.callout).foregroundStyle(.secondary)
            if settings.isLoading {
                ProgressView("Opening app vocabulary and history…")
            } else {
                Text("\(settings.memory.vocabulary.count) vocabulary entries · \(settings.memory.history.count) history entries")
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
        } header: {
            Text("App Vocabulary and History")
        } footer: {
            Text("Both options are off by default and stay on this Mac. Vocabulary expires after 90 days without use (5,000 entries total); history after 30 days (1,000 entries total, up to 4,096 bytes each for spelling and text). Editing committed text, shortcuts, focus changes and secure input discard unfinished history. No document or clipboard content is read. You can pause either feature for an individual app in Manage App Data.")
        }
        .sheet(isPresented: $showsManager) { ApplicationMemoryView(settings: settings) }
        .confirmationDialog("Clear all app vocabulary and history?", isPresented: $showsClearConfirmation) {
            Button("Clear All App Data", role: .destructive) { settings.clearAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes every app’s vocabulary and history on this Mac. Explicit personal phrases and shared learning are kept.")
        }
    }
}
