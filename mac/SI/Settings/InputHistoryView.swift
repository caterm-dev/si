import SwiftUI

struct InputHistoryView: View {
    let history: InputHistorySettings
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var showsClearConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Input History").font(.title2.bold())
            Text("Each row is one SI submission. Prefix selections and automatic confirmations appear separately; text typed outside SI is not included.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Search history spelling or text", text: $search).textFieldStyle(.roundedBorder)
            List(history.entries) { entry in
                InputHistoryRow(entry: entry) { history.remove(id: entry.id) }
            }
            .overlay {
                if history.isReading { ProgressView("Opening input history…") }
                else if history.entries.isEmpty {
                    ContentUnavailableView("No Input History", systemImage: "clock",
                                           description: Text("Enable Save Input History to record future SI submissions."))
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
                Button("Clear Input History…", role: .destructive) { showsClearConfirmation = true }
                    .disabled(history.isLoading || history.isClearing)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 700, minHeight: 500)
        .task(id: search) { await history.refresh(search: search) }
        .confirmationDialog("Clear all input history?", isPresented: $showsClearConfirmation) {
            Button("Clear Input History", role: .destructive) { history.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Permanently deletes saved input history and pending unsaved history. Personal Learning and personal phrases are kept.")
        }
    }
}
