import SwiftUI

struct InputHistorySection: View {
    @Bindable var history: InputHistorySettings
    @State private var showsHistory = false
    @State private var showsClearConfirmation = false

    var body: some View {
        let saveTitle = L10n.text(history.savesSentences ? "Save Complete Sentences" : "Save Input History")

        SettingsGroup("Recording") {
            SettingsRow(title: Text(saveTitle), detail: recordingDescription) {
                Toggle(saveTitle, isOn: $history.enabled)
                    .labelsHidden()
                    .disabled(history.isLoading || history.isClearing)
            }
            if history.savesSentences, history.enabled {
                Text(history.sentenceCaptureDescription)
                    .font(.callout).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Divider()
            if history.savesSentences {
                Text("Off by default. Sentences are stored separately on this Mac until deleted. Secure input and direct-input apps are excluded. Stored sentences are not encrypted.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Off by default and independent of Personal Learning. History can contain private text, including original English input and personal phrases. Secure input and direct-input apps are excluded. Text typed outside SI is not captured. Stored history is not encrypted; other software running as you and backups may access it.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        SettingsGroup("Saved Data") {
            HStack {
                Button(L10n.text(history.savesSentences ? "View Saved Sentences…" : "View Input History…")) { showsHistory = true }
                    .sheet(isPresented: $showsHistory) { InputHistoryView(history: history) }
                InputHistoryExportButton(history: history)
            }
            Divider()
            Button(history.clearTitle, role: .destructive) { showsClearConfirmation = true }
                .disabled(history.isLoading || history.isClearing)
                .confirmationDialog(history.clearConfirmationTitle, isPresented: $showsClearConfirmation) {
                    Button(history.clearAction, role: .destructive) { history.clear() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(history.clearMessage)
                }
            if history.isLoading { ProgressView("Opening input history…") }
            if history.isSaving { ProgressView("Saving input history…").controlSize(.small) }
            if history.isExporting { ProgressView("Exporting input history…") }
            if let notice = history.exportNotice { Text(notice).foregroundStyle(.secondary).textSelection(.enabled) }
            if let error = history.exportError { Text(error).foregroundStyle(.red) }
            if let error = history.errorMessage {
                Text(error).foregroundStyle(.red)
                if history.pendingRetryCount > 0 {
                    Text(L10n.format("Pending history records: %ld", history.pendingRetryCount))
                    Button("Retry Saving History") { history.retrySaving() }
                }
                if history.canReopen {
                    Button("Reopen History") { Task { await history.reopen() } }
                }
            }
        }
    }

    private var recordingDescription: Text {
        if history.savesSentences {
            Text("In all apps where SI conversion is active, press Return after submitting text with SI to save available single-line text before the caret. Completeness is not checked; saved text may be partial and may include edits, pasted text and existing content.")
        } else {
            Text("Saves each SI submission with its original spelling, submitted text and time. Repeated submissions are separate records. History stays on this Mac until you delete it, without automatic expiry or a record-count limit.")
        }
    }
}
