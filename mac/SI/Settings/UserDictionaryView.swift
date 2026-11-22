import SwiftUI

struct UserDictionaryView: View {
    let dictionary: SentenceLearningSettings
    @State private var search = ""
    @State private var editor: PhraseEditorRequest?
    @State private var errorMessage: String?
    @State private var showsDeleteAllConfirmation = false

    private var visibleEntries: [UserLexiconEntry] {
        dictionary.entries.filter {
            search.isEmpty || $0.reading.localizedStandardContains(search) || $0.text.localizedStandardContains(search)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SI learns from confirmed candidates and spelling you submit with Return. Words and counts stay on this Mac.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Search phrases or input codes", text: $search).textFieldStyle(.roundedBorder)
            HStack {
                Button("Add Phrase…") { editor = PhraseEditorRequest(phrase: nil) }
                    .disabled(!dictionary.canEditEntries)
                Spacer()
                Button("Delete All…", role: .destructive) { showsDeleteAllConfirmation = true }
                    .disabled(!dictionary.canClearAll)
                    .confirmationDialog("Delete all personal phrases?", isPresented: $showsDeleteAllConfirmation) {
                        Button("Delete All", role: .destructive, action: deleteAll)
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Deletes all personal phrases and learned word statistics on this Mac.")
                    }
            }
            List(visibleEntries) { phrase in
                HStack {
                    VStack(alignment: .leading) {
                        Text(verbatim: phrase.text).font(.headline).lineLimit(3)
                        Text(verbatim: "\(phrase.reading) · \(phrase.index == 0 ? L10n.text("Chinese (Simplified)") : phrase.index == 1 ? L10n.text("English") : L10n.text("No reading")) · \(phrase.count)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    Spacer()
                    Button("Edit") { editor = PhraseEditorRequest(phrase: phrase) }
                        .accessibilityLabel(L10n.format("Edit phrase %@, code %@", phrase.text, phrase.reading))
                    Button("Delete", role: .destructive) {
                        Task {
                            do { try await dictionary.editEntry(old: phrase, new: nil); errorMessage = nil }
                            catch { errorMessage = L10n.text("The entry could not be saved. It may have changed; refresh and try again.") }
                        }
                    }
                    .accessibilityLabel(L10n.format("Delete phrase %@, code %@", phrase.text, phrase.reading))
                }
                .disabled(!dictionary.canEditEntries)
            }
            .frame(minHeight: 320)
            .overlay {
                if visibleEntries.isEmpty {
                    ContentUnavailableView("No Personal Phrases", systemImage: "text.badge.plus",
                                           description: Text("Add a phrase or try another search."))
                }
            }
            if dictionary.isClearing { ProgressView("Deleting personal phrases…").controlSize(.small) }
            else if dictionary.isLoading || dictionary.isEditing { ProgressView().controlSize(.small) }
            if let error = dictionary.errorMessage ?? errorMessage { Text(error).foregroundStyle(.red) }
            if dictionary.canRetry { Button("Retry Sentence Learning", action: dictionary.retry) }
            Text(L10n.format("Personal phrases: %ld", dictionary.entries.count))
                .font(.caption).foregroundStyle(.secondary)
        }
        .sheet(item: $editor) { request in UserPhraseEditor(dictionary: dictionary, phrase: request.phrase) }
    }

    private func deleteAll() {
        errorMessage = nil
        dictionary.clear()
    }
}
