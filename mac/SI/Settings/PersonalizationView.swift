import SwiftUI

struct PersonalizationView: View {
    @Bindable var personalization: PersonalizationSettings
    @State private var showsClearConfirmation = false
    @State private var showsEntries = false

    var body: some View {
        Section {
            Toggle("Personal learning", isOn: $personalization.isEnabled)
                .disabled(personalization.isLoading)
            Toggle("Learn from the previous chosen word", isOn: $personalization.contextEnabled)
                .disabled(!personalization.isEnabled || personalization.isLoading)
            if personalization.contextEnabled {
                Text("When learning is enabled, this also saves aggregate pairs of chosen words. The previous word is used in the current typing session for up to five minutes; cancelling input or leaving the field resets it. Personal phrases are excluded. Turning this option off stops using word pairs; clear saved data to delete existing pairs.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if personalization.isLoading {
                ProgressView("Opening saved preferences…")
            } else {
                Text("\(personalization.entries.count) saved preferences")
                    .foregroundStyle(.secondary)
                if personalization.isSaving {
                    ProgressView("Saving changes…").controlSize(.small)
                }
                HStack {
                    Button("Manage Saved Preferences…") { showsEntries = true }
                        .disabled(personalization.entries.isEmpty)
                    Button("Clear Saved Data…", role: .destructive) { showsClearConfirmation = true }
                        .disabled(personalization.entries.isEmpty && personalization.errorMessage == nil)
                }
            }
            if let error = personalization.errorMessage {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
                if personalization.canRetrySaving {
                    Button("Retry Saving") { Task { await personalization.flush() } }
                }
            }
        } header: {
            Text("Personalization")
        } footer: {
            Text("Off by default. When enabled, SI saves deliberate choices made with number keys, the mouse, or navigation followed by Space, only on this Mac. Simply pressing Space to accept the default does not train learning. Chinese single-character preferences apply only to the same spelling; words with two or more characters can also influence longer compositions. Turning this off pauses learning and personalized ranking; saved data remains until you delete it. Preferences expire after 90 days without use, with a maximum of 5,000 entries. Original text, shortcuts, and cancelled input are never learned.")
        }
        .confirmationDialog("Clear all saved learning data?", isPresented: $showsClearConfirmation) {
            Button("Clear Saved Data", role: .destructive) { personalization.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes SI’s saved preferences on this Mac. Language settings will be kept.")
        }
        .sheet(isPresented: $showsEntries) {
            LearnedPreferencesView(personalization: personalization)
        }
    }
}
