import SwiftUI

struct UserPhraseEditor: View {
    let dictionary: SentenceLearningSettings
    private let original: UserLexiconEntry?
    @Environment(\.dismiss) private var dismiss
    @State private var input: String
    @State private var text: String
    @State private var index: UInt32
    @State private var count: String
    @State private var errorMessage: String?
    @State private var saving = false

    init(dictionary: SentenceLearningSettings, phrase: UserLexiconEntry?) {
        self.dictionary = dictionary
        original = phrase
        _input = State(initialValue: phrase?.reading ?? "")
        _text = State(initialValue: phrase?.text ?? "")
        _index = State(initialValue: phrase?.index ?? 0)
        _count = State(initialValue: String(phrase?.count ?? 1))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text(original == nil ? "Add Personal Phrase" : "Edit Personal Phrase")).font(.title2.bold())
            Form {
                TextField("Phrase", text: $text)
                Picker("Candidate language", selection: $index) {
                    Text("Chinese (Simplified)").tag(UInt32(0))
                    Text("English").tag(UInt32(1))
                    Text("No reading").tag(UInt32.max)
                }
                TextField("Input code", text: $input).disabled(index == .max)
                TextField("Frequency", text: $count)
            }
            Text("Enter lowercase Pinyin or English spelling. Entries use dictionary ranking; there is no pin or shortcut expansion.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
                    .disabled(saving || !dictionary.canEditEntries || text.isEmpty || UInt64(count) == nil || (index != .max && input.isEmpty))
            }
        }
        .padding(24).frame(minWidth: 480)
        .interactiveDismissDisabled(saving)
    }

    private func save() {
        guard let frequency = UInt64(count) else { return }
        saving = true
        Task {
            do {
                try await dictionary.editEntry(old: original, new: UserLexiconEntry(
                    text: text, reading: index == .max ? "" : input, index: index, count: frequency))
                dismiss()
            } catch {
                errorMessage = L10n.text("The entry could not be saved. Check the spelling and duplicates, or reopen the editor if the entry changed.")
            }
            saving = false
        }
    }
}
