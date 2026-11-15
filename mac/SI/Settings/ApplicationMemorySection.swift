import SwiftUI

struct ApplicationMemorySection: View {
    @Bindable var settings: ApplicationMemorySettings
    @State private var showsManager = false
    @State private var showsClearConfirmation = false
    @State private var showsLegacyClearConfirmation = false
    @State private var showsSentenceHistoryClearConfirmation = false

    var body: some View {
        SettingsGroup("Learning") {
            SettingsRow(
                title: Text("Enable Personal Learning"),
                detail: Text("Shares learned vocabulary across apps. A deliberate choice of a later candidate becomes the first choice for the same spelling next time, unless a personal phrase is pinned. Frequency rewards remain capped at 32 points. Learning does not decay or expire; turning it off returns to base ranking.")
            ) {
                Toggle("Enable Personal Learning", isOn: $settings.vocabularyEnabled)
                    .labelsHidden()
                    .disabled(settings.isLoading)
            }
            Divider()
            Text("Personal Learning is off by default and stays on this Mac. It keeps up to 5,000 global entries; when full, the least recently used entries are removed. Candidate-choice learning uses the text you confirm.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        SentenceLearningSection(settings: settings.sentences, vocabularyEnabled: settings.vocabularyEnabled)
        SettingsGroup("Saved Data") {
            if settings.isLoading {
                ProgressView("Opening learning data…")
            } else {
                SettingsRow(title: Text(L10n.format("Learning entries: %ld", settings.memory.vocabulary.count))) {
                    Button("Manage Learning Data…") { showsManager = true }
                        .sheet(isPresented: $showsManager) { ApplicationMemoryView(settings: settings) }
                }
                Divider()
                Button("Clear All Learning Data…", role: .destructive) { showsClearConfirmation = true }
                    .disabled(!settings.canClearAll)
                    .confirmationDialog("Clear all learning data?", isPresented: $showsClearConfirmation) {
                        Button("Clear All Learning Data", role: .destructive) { settings.clearAll() }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Deletes learned vocabulary and the sentence model on this Mac. Explicit personal phrases are kept.")
                    }
                if settings.isSaving || settings.sentences.isClearing { ProgressView("Saving learning data…").controlSize(.small) }
            }
            if let error = settings.errorMessage {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
                if settings.canRetrySaving { Button("Retry Saving") { Task { await settings.flush() } } }
            }
        }
        if settings.hasLegacyLearningData || settings.legacyRemovalError != nil || settings.sentences.hasRetiredHistory {
            SettingsGroup("Legacy Data") {
                if settings.hasLegacyLearningData {
                    Text("The legacy learning archive is no longer used. You can delete it without affecting Personal Learning or personal phrases.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Delete Old Shared Learning Data…", role: .destructive) { showsLegacyClearConfirmation = true }
                        .disabled(settings.isRemovingLegacyData)
                        .confirmationDialog("Delete old shared learning data?", isPresented: $showsLegacyClearConfirmation) {
                            Button("Delete Old Shared Learning Data", role: .destructive) { settings.clearLegacyLearningData() }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("Deletes the legacy learning archive on this Mac. Current Personal Learning data and explicit personal phrases are kept.")
                        }
                    if settings.isRemovingLegacyData { ProgressView("Deleting old shared data…").controlSize(.small) }
                }
                if let error = settings.legacyRemovalError { Text(error).foregroundStyle(.red) }
                if settings.sentences.hasRetiredHistory {
                    Button("Delete Old Sentence History…", role: .destructive) { showsSentenceHistoryClearConfirmation = true }
                        .disabled(settings.sentences.isDeletingRetiredHistory)
                        .confirmationDialog("Delete old Sentence History?", isPresented: $showsSentenceHistoryClearConfirmation) {
                            Button("Delete Old Sentence History", role: .destructive, action: settings.sentences.deleteRetiredHistory)
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("Deletes sentences saved by the former Sentence History feature on this Mac.")
                        }
                }
                if let error = settings.sentences.retiredHistoryError { Text(error).foregroundStyle(.red) }
            }
        }
    }
}
