import SwiftUI

struct InputHistorySection: View {
    @Bindable var history: InputHistorySettings
    @State private var showsHistory = false
    @State private var showsClearConfirmation = false

    var body: some View {
        Section {
            Toggle("Save Input History", isOn: $history.enabled)
                .disabled(history.isLoading || history.isClearing)
            Text("Saves each SI submission with its original spelling, submitted text and time. Repeated submissions are separate records. History stays on this Mac until you delete it, without automatic expiry or a record-count limit.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("View Input History…") { showsHistory = true }
                InputHistoryExportButton(history: history)
                Button("Clear Input History…", role: .destructive) { showsClearConfirmation = true }
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
            Text("Input History")
        } footer: {
            Text("Off by default and independent of Personal Learning. History can contain private text, including original English input and personal phrases. Secure input and direct-input apps are excluded. Text typed outside SI is not captured. Stored history is not encrypted; other software running as you and backups may access it.")
        }
        .sheet(isPresented: $showsHistory) { InputHistoryView(history: history) }
        .confirmationDialog("Clear all input history?", isPresented: $showsClearConfirmation) {
            Button("Clear Input History", role: .destructive) { history.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Permanently deletes saved input history and pending unsaved history. Personal Learning and personal phrases are kept.")
        }
    }
}
