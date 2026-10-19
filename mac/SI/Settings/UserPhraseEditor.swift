import SwiftUI

struct UserPhraseEditor: View {
    let dictionary: UserDictionarySettings
    private let phraseID: UUID
    private let isNew: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var input: String
    @State private var text: String
    @State private var language: InputLanguage
    @State private var isPinned: Bool
    @State private var errorMessage: String?

    init(dictionary: UserDictionarySettings, phrase: UserPhrase?) {
        self.dictionary = dictionary
        phraseID = phrase?.id ?? UUID()
        isNew = phrase == nil
        _input = State(initialValue: phrase?.input ?? "")
        _text = State(initialValue: phrase?.text ?? "")
        _language = State(initialValue: phrase?.language ?? .simplifiedChinese)
        _isPinned = State(initialValue: phrase?.isPinned ?? false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? "Add Personal Phrase" : "Edit Personal Phrase").font(.title2.bold())
            Form {
                TextField("Input code", text: $input)
                TextField("Phrase", text: $text)
                Picker("Candidate language", selection: $language) {
                    ForEach(InputLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                Toggle("Prefer this phrase for its full code", isOn: $isPinned)
            }
            Text("Use letters and apostrophes for the code, such as xm or xiang'mu. Use v for ü. The phrase is inserted exactly as saved, and its language must be enabled in Settings.")
                .font(.callout).foregroundStyle(.secondary)
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction)
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.isEmpty || !dictionary.canEdit)
            }
        }
        .padding(24)
        .frame(minWidth: 480)
    }

    private func save() {
        do {
            let phrase = try UserPhrase(id: phraseID, input: input, text: text, language: language, isPinned: isPinned)
            try dictionary.save(phrase)
            dismiss()
        } catch UserPhrase.ValidationError.invalidInput {
            errorMessage = "Use 1–64 letters, with apostrophes only between letters."
        } catch UserPhrase.ValidationError.invalidText {
            errorMessage = "Enter a nonempty phrase on one line, without control characters. Shorten it if it is too long."
        } catch UserDictionary.DictionaryError.duplicatePhrase {
            errorMessage = "This code, language, and phrase are already saved. Edit the existing entry instead."
        } catch UserDictionary.DictionaryError.capacityExceeded {
            errorMessage = "The dictionary is full. Remove an entry before adding another phrase."
        } catch {
            errorMessage = "This phrase could not be saved. Close the editor and check the dictionary status."
        }
    }
}
