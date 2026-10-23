import SwiftUI

struct ApplicationMemoryView: View {
    let settings: ApplicationMemorySettings
    @Environment(\.dismiss) private var dismiss
    @State private var applicationID = ""
    @State private var search = ""
    @State private var showsHistory = false
    @State private var showsClearConfirmation = false

    private var vocabulary: [ApplicationVocabularyEntry] {
        settings.memory.vocabulary.filter {
            (applicationID.isEmpty || $0.applicationID == applicationID)
                && matches(input: $0.preference.input, text: $0.preference.text, app: $0.applicationID)
        }
    }

    private var history: [ApplicationHistoryEntry] {
        settings.memory.history.filter {
            (applicationID.isEmpty || $0.applicationID == applicationID) && matches(input: $0.input, text: $0.text, app: $0.applicationID)
        }
    }

    private func matches(input: String, text: String, app: String) -> Bool {
        search.isEmpty || input.localizedStandardContains(search) || text.localizedStandardContains(search)
            || app.localizedStandardContains(search)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("App Vocabulary and History").font(.title2.bold())
            Picker("Application", selection: $applicationID) {
                Text("All Applications").tag("")
                ForEach(settings.applicationIDs, id: \.self) { Text($0).tag($0) }
            }
            .onChange(of: settings.applicationIDs) {
                if !settings.applicationIDs.contains(applicationID) { applicationID = "" }
            }
            if !applicationID.isEmpty {
                HStack {
                    Button(settings.vocabularyExclusions.contains(applicationID) ? "Resume App Vocabulary" : "Pause App Vocabulary") {
                        settings.setVocabularyAllowed(settings.vocabularyExclusions.contains(applicationID), applicationID: applicationID)
                    }
                    Button(settings.historyExclusions.contains(applicationID) ? "Resume App History" : "Pause App History") {
                        settings.setHistoryAllowed(settings.historyExclusions.contains(applicationID), applicationID: applicationID)
                    }
                }
                Text("Pausing stops recording and suggestions for this app. Existing entries remain until deleted.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker("Saved data", selection: $showsHistory) {
                Text("Vocabulary").tag(false)
                Text("History").tag(true)
            }
            .pickerStyle(.segmented)
            TextField("Search words, input, or application", text: $search).textFieldStyle(.roundedBorder)
            if showsHistory {
                List(history) { entry in
                    ApplicationMemoryRow(text: entry.text, input: entry.input, applicationID: entry.applicationID,
                                         count: entry.count, lastUsed: entry.lastUsed) { settings.removeHistory(id: entry.id) }
                }
                .overlay {
                    if history.isEmpty {
                        ContentUnavailableView("No App History", systemImage: "clock.arrow.circlepath",
                                               description: Text("Enable app history, type with SI, then press Return after finishing composition."))
                    }
                }
            } else {
                List(vocabulary) { entry in
                    ApplicationMemoryRow(text: entry.preference.text, input: entry.preference.input, applicationID: entry.applicationID,
                                         count: entry.count, lastUsed: entry.preference.lastUsed) { settings.removeVocabulary(id: entry.id) }
                }
                .overlay {
                    if vocabulary.isEmpty {
                        ContentUnavailableView("No App Vocabulary", systemImage: "text.magnifyingglass",
                                               description: Text("Enable app vocabulary and confirm candidates while typing."))
                    }
                }
            }
            if let error = settings.errorMessage { Text(error).foregroundStyle(.red) }
            HStack {
                Button(showsHistory ? "Clear History…" : "Clear Vocabulary…", role: .destructive) { showsClearConfirmation = true }
                    .disabled(showsHistory ? history.isEmpty : vocabulary.isEmpty)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 660, minHeight: 480)
        .confirmationDialog(showsHistory ? "Clear saved history?" : "Clear saved vocabulary?", isPresented: $showsClearConfirmation) {
            Button("Clear", role: .destructive, action: clearSelectedData)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(applicationID.isEmpty ? "Deletes this data for every application, including entries hidden by the search."
                 : "Deletes this data for \(applicationID), including entries hidden by the search.")
        }
    }

    private func clearSelectedData() {
        let scope = applicationID.isEmpty ? nil : applicationID
        if showsHistory { settings.clearHistory(applicationID: scope) }
        else { settings.clearVocabulary(applicationID: scope) }
    }
}
