import SwiftUI
import UniformTypeIdentifiers

struct UserDictionaryView: View {
    let dictionary: UserDictionarySettings
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var editor: PhraseEditorRequest?
    @State private var showsImporter = false
    @State private var showsExporter = false
    @State private var showsClearConfirmation = false
    @State private var preparingExport = false
    @State private var exportDocument: UserDictionaryDocument?

    private var visibleEntries: [UserPhrase] {
        dictionary.entries.filter {
            search.isEmpty || $0.input.localizedStandardContains(search) || $0.text.localizedStandardContains(search)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Personal Phrases").font(.title2.bold())
            TextField("Search phrases or input codes", text: $search).textFieldStyle(.roundedBorder)
            HStack {
                Button("Add Phrase…") { editor = PhraseEditorRequest(phrase: nil) }.disabled(!dictionary.canEdit)
                Button("Import…") { showsImporter = true }.disabled(!dictionary.canEdit || dictionary.isImporting)
                Button("Export…", action: prepareExport)
                    .disabled(!dictionary.canEdit || dictionary.entries.isEmpty || preparingExport)
                Spacer()
                Button("Clear Dictionary…", role: .destructive) { showsClearConfirmation = true }
                    .disabled(dictionary.isLoading || (dictionary.entries.isEmpty && dictionary.errorMessage == nil))
                    .confirmationDialog("Clear all personal phrases?", isPresented: $showsClearConfirmation) {
                        Button("Clear Dictionary", role: .destructive, action: dictionary.clear)
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This removes your saved phrases on this Mac. Exported copies and learning preferences are kept.")
                    }
            }
            List(visibleEntries) { phrase in
                HStack {
                    VStack(alignment: .leading) {
                        Text(phrase.text).font(.headline).lineLimit(3)
                        Text("\(phrase.input) · \(phrase.language.displayName)\(phrase.isPinned ? " · Preferred" : "")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    Spacer()
                    Button("Edit") { editor = PhraseEditorRequest(phrase: phrase) }
                        .accessibilityLabel("Edit phrase \(phrase.text), code \(phrase.input)")
                        .disabled(!dictionary.canEdit)
                    Button("Delete", role: .destructive) { dictionary.remove(id: phrase.id) }
                        .accessibilityLabel("Delete phrase \(phrase.text), code \(phrase.input)")
                        .disabled(!dictionary.canEdit)
                }
            }
            .overlay {
                if visibleEntries.isEmpty {
                    ContentUnavailableView("No Personal Phrases", systemImage: "text.badge.plus",
                                           description: Text("Add a phrase or try another search."))
                }
            }
            if dictionary.isSaving { ProgressView("Saving phrases…").controlSize(.small) }
            if dictionary.isImporting { ProgressView("Importing phrases…").controlSize(.small) }
            if let notice = dictionary.notice { Text(notice).font(.callout).foregroundStyle(.secondary) }
            if let error = dictionary.errorMessage {
                Text(error).foregroundStyle(.red)
                if dictionary.canRetrySaving {
                    Button("Retry Saving") { Task { await dictionary.flush() } }
                }
            }
            HStack {
                Text("\(dictionary.entries.count) of \(UserDictionary.maximumEntries) phrases · No automatic expiry")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 640, minHeight: 480)
        .sheet(item: $editor) { request in UserPhraseEditor(dictionary: dictionary, phrase: request.phrase) }
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.json], onCompletion: importResult)
        .fileExporter(isPresented: $showsExporter, document: exportDocument, contentType: .json,
                      defaultFilename: "SI-User-Phrases", onCompletion: exportResult)
    }

    private func prepareExport() {
        preparingExport = true
        Task {
            if let data = await dictionary.exportData() {
                exportDocument = UserDictionaryDocument(data: data)
                showsExporter = true
            }
            preparingExport = false
        }
    }

    private func importResult(_ result: Result<URL, any Error>) {
        switch result {
        case .success(let url): Task { await dictionary.importFile(url) }
        case .failure(let error): reportUnlessCancelled(error)
        }
    }

    private func exportResult(_ result: Result<URL, any Error>) {
        if case .failure(let error) = result { reportUnlessCancelled(error) }
    }

    private func reportUnlessCancelled(_ error: any Error) {
        if (error as? CocoaError)?.code != .userCancelled { dictionary.reportFileActionFailure() }
    }
}
