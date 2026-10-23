import SwiftUI

@MainActor
struct CandidatePreviewView: View {
    let settings: LanguageSettings
    let dictionary: UserDictionarySettings
    var applicationMemory: ApplicationMemorySettings = .shared
    @State private var input = "shi"
    @State private var page = 0
    @State private var preview = CandidatePreviewModel()
    @State private var applicationID = ""
    private let pageSize = 8

    var body: some View {
        let query = currentQuery
        Picker("Preview application", selection: $applicationID) {
            Text("No Application").tag("")
            ForEach(applicationMemory.applicationIDs, id: \.self) { Text($0).tag($0) }
        }
        .onChange(of: applicationMemory.applicationIDs) {
            if !applicationMemory.applicationIDs.contains(applicationID) { applicationID = "" }
        }
        TextField("Type English or Pinyin", text: $input)
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("Candidate preview input")
            .task(id: query) {
                page = 0
                preview.submit(query) {
                    query == currentQuery
                }
            }
            .onDisappear { preview.cancel() }
        let results = preview.candidates
        let lastPage = max(0, (results.count - 1) / pageSize)
        let currentPage = min(page, lastPage)
        ForEach(results.dropFirst(currentPage * pageSize).prefix(pageSize)) { candidate in
            HStack {
                Text(candidate.text).font(.body.monospaced())
                Spacer()
                Text(candidate.label).font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
        if preview.isSearching {
            Text("Searching…").font(.caption).foregroundStyle(.secondary)
                .accessibilityLabel("Updating candidate preview")
        }
        if !results.isEmpty {
            HStack {
                Text("Page \(currentPage + 1) of \(lastPage + 1) · \(results.count) candidates")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Previous") { page = max(0, currentPage - 1) }.disabled(currentPage == 0)
                Button("Next") { page = currentPage + 1 }.disabled(currentPage == lastPage)
            }
        }
        if settings.enabledLanguages.isEmpty {
            Text("No languages are enabled. SI will keep text as typed.").foregroundStyle(.secondary)
        }
    }

    private var currentQuery: CandidatePreviewQuery {
        let memory: ApplicationMemorySnapshot = applicationID.isEmpty ? .empty : applicationMemory.snapshot(for: applicationID)
        return CandidatePreviewQuery(input: input, languages: settings.enabledLanguages,
                                     learning: memory.learning,
                                     dictionary: dictionary.dictionaryForInput, applicationMemory: memory)
    }
}
