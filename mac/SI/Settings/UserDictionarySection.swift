import SwiftUI

struct UserDictionarySection: View {
    let dictionary: UserDictionarySettings
    @State private var showsDictionary = false

    var body: some View {
        Section {
            if dictionary.isLoading {
                ProgressView("Opening personal phrases…")
            } else {
                Text(L10n.format("Personal phrases: %ld", dictionary.entries.count)).foregroundStyle(.secondary)
                Button("Manage Personal Phrases…") { showsDictionary = true }
            }
            if let error = dictionary.errorMessage {
                Text(error).foregroundStyle(.red)
            }
        } header: {
            Text("Personal Phrases")
        } footer: {
            Text("Save your own words and shortcuts explicitly. Phrases work independently of personal learning and stay on this Mac until you delete them. You can edit, pin, import, or export them. Exported files contain your phrase text.")
        }
        .sheet(isPresented: $showsDictionary) { UserDictionaryView(dictionary: dictionary) }
    }
}
