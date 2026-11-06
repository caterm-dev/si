import SwiftUI

struct InputHistorySection: View {
    @Bindable var history: InputHistorySettings
    @State private var showsHistory = false
    @State private var showsClearConfirmation = false

    var body: some View {
        Section {
            Toggle(L10n.text(history.savesSentences ? "Save Complete Sentences" : "Save Input History"), isOn: $history.enabled)
                .disabled(history.isLoading || history.isClearing)
            if history.savesSentences {
                Text("In apps you add below, SI can save the complete text of a supported single-line input when you press Return at the end after submitting text with SI. This may include edits, pasted text and text already in the input.")
                    .font(.callout).foregroundStyle(.secondary)
                SentenceHistoryApplications(history: history)
            } else {
                Text("Saves each SI submission with its original spelling, submitted text and time. Repeated submissions are separate records. History stays on this Mac until you delete it, without automatic expiry or a record-count limit.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button(L10n.text(history.savesSentences ? "View Saved Sentences…" : "View Input History…")) { showsHistory = true }
                InputHistoryExportButton(history: history)
                Button(history.clearTitle, role: .destructive) { showsClearConfirmation = true }
                    .disabled(history.isLoading || history.isClearing)
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
        } header: {
            Text(history.sectionTitle)
        } footer: {
            if history.savesSentences {
                Text("Off by default. Sentences are stored separately on this Mac until deleted. Secure input and direct-input apps are excluded. Stored sentences are not encrypted.")
            } else {
                Text("Off by default and independent of Personal Learning. History can contain private text, including original English input and personal phrases. Secure input and direct-input apps are excluded. Text typed outside SI is not captured. Stored history is not encrypted; other software running as you and backups may access it.")
            }
        }
        .sheet(isPresented: $showsHistory) { InputHistoryView(history: history) }
        .confirmationDialog(history.clearConfirmationTitle, isPresented: $showsClearConfirmation) {
            Button(history.clearAction, role: .destructive) { history.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(history.clearMessage)
        }
    }
}
