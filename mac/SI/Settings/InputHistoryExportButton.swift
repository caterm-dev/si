import SwiftUI
import UniformTypeIdentifiers

struct InputHistoryExportButton: View {
    let history: InputHistorySettings

    var body: some View {
        Button("Export Input History…", action: chooseDestination)
            .disabled(history.isLoading || history.isClearing || history.isExporting)
    }

    private func chooseDestination() {
        let panel = NSSavePanel()
        panel.title = L10n.text("Export Input History")
        panel.nameFieldStringValue = "SI-Input-History.jsonl"
        panel.allowedContentTypes = [UTType(filenameExtension: "jsonl", conformingTo: .plainText) ?? .plainText]
        panel.message = L10n.text("Exports all saved spelling, text and timestamps to one JSONL file, including private input and personal phrases. SI does not upload or send it. Deleting local history does not delete exported copies.")
        panel.begin { result in
            guard result == .OK, let destination = panel.url else { return }
            Task { await history.export(to: destination) }
        }
    }
}
