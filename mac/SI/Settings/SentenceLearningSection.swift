import SwiftUI

struct SentenceLearningSection: View {
    @Bindable var settings: SentenceLearningSettings
    @State private var showsClearConfirmation = false
    @State private var showsRetiredHistoryConfirmation = false

    var body: some View {
        SettingsGroup("Learning") {
            SettingsRow(
                title: Text("Learn from Submitted Sentences"),
                detail: Text("When you press Return outside a composition, SI can learn from the entire input field, including existing or pasted text and text after the caret.")
            ) {
                Toggle("Learn from Submitted Sentences", isOn: $settings.enabled)
                    .labelsHidden()
                    .disabled(settings.isLoading || settings.isClearing)
            }
            Text("Off by default. Learned words and word counts stay on this Mac and can change candidate ranking. SI discards the captured text after processing it.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if settings.enabled, settings.errorMessage == nil, let status = settings.captureStatus {
                Text(status.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }

        SettingsGroup("Sentence Model") {
            Button("Clear Sentence Learning Data…", role: .destructive) { showsClearConfirmation = true }
                .disabled(settings.isLoading || settings.isClearing || !settings.hasDataOrError)
                .confirmationDialog("Clear sentence learning data?", isPresented: $showsClearConfirmation) {
                    Button("Clear Sentence Learning Data", role: .destructive, action: settings.clear)
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Deletes the sentence model and pending sentence samples on this Mac.")
                }
            if settings.isLoading { ProgressView("Opening sentence learning data…") }
            if settings.isClearing { ProgressView("Clearing sentence learning data…") }
            if let error = settings.errorMessage {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
                if settings.canRetry {
                    Button("Retry Sentence Learning", action: settings.retry)
                }
            }
        }

        if settings.hasRetiredHistory || settings.retiredHistoryError != nil {
            SettingsGroup("Legacy Data") {
                if settings.hasRetiredHistory {
                    Button("Delete Old Sentence History…", role: .destructive) { showsRetiredHistoryConfirmation = true }
                        .disabled(settings.isDeletingRetiredHistory)
                        .confirmationDialog("Delete old Sentence History?", isPresented: $showsRetiredHistoryConfirmation) {
                            Button("Delete Old Sentence History", role: .destructive, action: settings.deleteRetiredHistory)
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("Deletes sentences saved by the former Sentence History feature on this Mac.")
                        }
                }
                if let error = settings.retiredHistoryError { Text(error).foregroundStyle(.red) }
            }
        }
    }
}
