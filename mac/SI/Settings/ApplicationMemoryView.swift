import SwiftUI

struct ApplicationMemoryView: View {
    let settings: ApplicationMemorySettings
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var showsClearConfirmation = false

    private var vocabulary: [ApplicationVocabularyEntry] {
        settings.memory.vocabulary.filter {
            search.isEmpty || $0.preference.input.localizedStandardContains(search)
                || $0.preference.text.localizedStandardContains(search)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Personal Learning").font(.title2.bold())
            Text("Learned words and counts are shared across apps. Forgetting an entry removes it everywhere.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Search words or input", text: $search).textFieldStyle(.roundedBorder)
            List(vocabulary) { entry in
                ApplicationMemoryRow(text: entry.preference.text, input: entry.preference.input,
                                     count: entry.count, lastUsed: entry.preference.lastUsed) { settings.removeVocabulary(id: entry.id) }
            }
            .overlay {
                if vocabulary.isEmpty {
                    ContentUnavailableView("No Learning Data", systemImage: "text.magnifyingglass",
                                           description: Text("Enable Personal Learning and confirm candidates while typing."))
                }
            }
            if let error = settings.errorMessage { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Clear Learning Data…", role: .destructive) { showsClearConfirmation = true }
                    .disabled(settings.memory.vocabulary.isEmpty)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 660, minHeight: 480)
        .confirmationDialog("Clear saved learning data?", isPresented: $showsClearConfirmation) {
            Button("Clear", role: .destructive) { settings.clearVocabulary() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes all learned vocabulary, including entries hidden by the search. Explicit personal phrases are kept.")
        }
    }
}
