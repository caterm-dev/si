import SwiftUI

struct InputHistoryView: View {
    let history: InputHistorySettings
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var showsClearConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(history.sectionTitle).font(.title2.bold())
            Text(L10n.text(history.savesSentences
                ? "Each row is the text SI read from the input before passing Return to the app."
                : "Each row is one SI submission. Prefix selections and automatic confirmations appear separately; text typed outside SI is not included."))
                .font(.callout).foregroundStyle(.secondary)
            TextField(L10n.text(history.savesSentences ? "Search saved sentences" : "Search history spelling or text"), text: $search)
                .textFieldStyle(.roundedBorder)
            List(history.entries) { entry in
                InputHistoryRow(entry: entry) { history.remove(id: entry.id) }
            }
            .overlay {
                if history.isReading { ProgressView("Opening input history…") }
                else if history.entries.isEmpty {
                    ContentUnavailableView(L10n.text(history.savesSentences ? "No Saved Sentences" : "No Input History"),
                                           systemImage: "clock", description: Text(L10n.text(history.savesSentences
                                            ? "Enable Save Complete Sentences and add an app to start saving."
                                            : "Enable Save Input History to record future SI submissions.")))
                }
            }
            if history.isExporting { ProgressView("Exporting input history…") }
            if let notice = history.exportNotice { Text(notice).foregroundStyle(.secondary).textSelection(.enabled) }
            if let error = history.exportError { Text(error).foregroundStyle(.red) }
            if let error = history.errorMessage {
                Text(error).foregroundStyle(.red)
                if history.pendingRetryCount > 0 {
                    Button("Retry Saving History") { history.retrySaving() }
                }
                if history.canReopen {
                    Button("Reopen History") { Task { await history.reopen() } }
                }
            }
            if let error = history.operationError { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Previous") { Task { await history.previousPage(search: search) } }
                    .disabled(!history.hasPreviousPage || history.isReading || history.isClearing)
                Button("Next") { Task { await history.nextPage(search: search) } }
                    .disabled(history.nextCursor == nil || history.isReading || history.isClearing)
                Text(L10n.format("Showing %ld records", history.entries.count)).foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") { Task { await history.refresh(search: search) } }
                    .disabled(history.isReading || history.isClearing)
            }
            HStack {
                InputHistoryExportButton(history: history)
                Button(history.clearTitle, role: .destructive) { showsClearConfirmation = true }
                    .disabled(history.isLoading || history.isClearing)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 700, minHeight: 500)
        .task(id: search) { await history.refresh(search: search) }
        .confirmationDialog(history.clearConfirmationTitle, isPresented: $showsClearConfirmation) {
            Button(history.clearAction, role: .destructive) { history.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(history.clearMessage)
        }
    }
}

extension InputHistorySettings {
    var sectionTitle: String { L10n.text(savesSentences ? "Sentence History" : "Input History") }
    var clearTitle: String { L10n.text(savesSentences ? "Clear Saved Sentences…" : "Clear Input History…") }
    var clearConfirmationTitle: String { L10n.text(savesSentences ? "Clear all saved sentences?" : "Clear all input history?") }
    var clearAction: String { L10n.text(savesSentences ? "Clear Saved Sentences" : "Clear Input History") }
    var clearMessage: String {
        L10n.text(savesSentences ? "Permanently deletes saved and pending sentences. Individual SI submissions are kept."
            : "Permanently deletes saved input history and pending unsaved history. Personal Learning and personal phrases are kept.")
    }
}
