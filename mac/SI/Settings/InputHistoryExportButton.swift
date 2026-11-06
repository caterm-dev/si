import SwiftUI
import UniformTypeIdentifiers

struct InputHistoryExportButton: View {
    let history: InputHistorySettings

    var body: some View {
        Button(L10n.text(history.savesSentences ? "Export Saved Sentences…" : "Export Input History…"), action: chooseDestination)
            .disabled(history.isLoading || history.isClearing || history.isExporting)
    }

    private func chooseDestination() {
        let panel = NSSavePanel()
        panel.title = L10n.text(history.savesSentences ? "Export Saved Sentences" : "Export Input History")
        panel.nameFieldStringValue = history.savesSentences ? "SI-Sentence-History.jsonl" : "SI-Input-History.jsonl"
        panel.allowedContentTypes = [UTType(filenameExtension: "jsonl", conformingTo: .plainText) ?? .plainText]
        panel.message = L10n.text(history.savesSentences
            ? "Exports all saved sentences and timestamps to one JSONL file. It can contain private text. SI does not upload or send it. Deleting local sentences does not delete exported copies."
            : "Exports all saved spelling, text and timestamps to one JSONL file, including private input and personal phrases. SI does not upload or send it. Deleting local history does not delete exported copies.")
        panel.begin { result in
            guard result == .OK, let destination = panel.url else { return }
            Task { await history.export(to: destination) }
        }
    }
}
