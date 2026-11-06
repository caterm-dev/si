import SwiftUI

struct UserDictionarySection: View {
    let dictionary: UserDictionarySettings
    @State private var showsDictionary = false

    var body: some View {
        SettingsGroup("Dictionary") {
            if dictionary.isLoading {
                ProgressView("Opening personal phrases…")
            } else {
                SettingsRow(title: Text(L10n.format("Personal phrases: %ld", dictionary.entries.count))) {
                    Button("Manage Personal Phrases…") { showsDictionary = true }
                }
            }
            if let error = dictionary.errorMessage {
                Text(error).foregroundStyle(.red)
            }
            Divider()
            Text("Save your own words and shortcuts explicitly. Phrases work independently of personal learning and stay on this Mac until you delete them. You can edit, pin, import, or export them. Exported files contain your phrase text.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .sheet(isPresented: $showsDictionary) { UserDictionaryView(dictionary: dictionary) }
    }
}
