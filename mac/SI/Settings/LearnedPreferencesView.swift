import SwiftUI

struct LearnedPreferencesView: View {
    let personalization: PersonalizationSettings
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var visibleEntries: [LearnedPreference] {
        personalization.entries.filter {
            search.isEmpty || $0.input.localizedStandardContains(search) || $0.text.localizedStandardContains(search)
                || $0.context?.text.localizedStandardContains(search) == true
        }
    }

    var body: some View {
        VStack(alignment: .leading) {
            Text("Saved Preferences").font(.title2.bold())
            TextField("Search words or input", text: $search)
                .textFieldStyle(.roundedBorder)
            List(visibleEntries) { entry in
                HStack {
                    VStack(alignment: .leading) {
                        Text(entry.text).font(.headline)
                        Text("\(entry.input) · \(entry.mixed == true ? "Chinese + English" : entry.language.displayName)")
                            .foregroundStyle(.secondary)
                        if let context = entry.context {
                            Text("After “\(context.text)”").font(.caption).foregroundStyle(.secondary)
                        }
                        Text(entry.lastUsed, format: .dateTime.year().month().day())
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    Spacer()
                    Button("Forget", role: .destructive) { personalization.remove(id: entry.id) }
                        .accessibilityLabel("Forget preference for \(entry.text), input \(entry.input)\(entry.context.map { " after " + $0.text } ?? "")")
                }
            }
            .overlay {
                if visibleEntries.isEmpty {
                    ContentUnavailableView("No Saved Preferences", systemImage: "text.magnifyingglass",
                                           description: Text("Try another search or choose candidates while personal learning is enabled."))
                }
            }
            if let error = personalization.errorMessage {
                Text(error).foregroundStyle(.red)
            }
            HStack {
                Text("Changes are saved automatically.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 520, minHeight: 420)
    }
}
