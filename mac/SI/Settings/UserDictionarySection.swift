import SwiftUI

struct UserDictionarySection: View {
    let dictionary: SentenceLearningSettings
    @State private var showsRetiredHistoryConfirmation = false

    var body: some View {
        UserDictionaryView(dictionary: dictionary)
        if dictionary.hasRetiredHistory || dictionary.retiredHistoryError != nil {
            SettingsGroup("Legacy Data") {
                if dictionary.hasRetiredHistory {
                    Button("Delete Old Sentence History…", role: .destructive) { showsRetiredHistoryConfirmation = true }
                        .disabled(dictionary.isDeletingRetiredHistory)
                        .confirmationDialog("Delete old Sentence History?", isPresented: $showsRetiredHistoryConfirmation) {
                            Button("Delete Old Sentence History", role: .destructive, action: dictionary.deleteRetiredHistory)
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("Deletes sentences saved by the former Sentence History feature on this Mac.")
                        }
                }
                if let error = dictionary.retiredHistoryError { Text(error).foregroundStyle(.red) }
            }
        }
    }
}
