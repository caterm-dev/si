import SwiftUI

struct CandidatePreviewView: View {
    let settings: LanguageSettings
    let personalization: PersonalizationSettings
    let dictionary: UserDictionarySettings
    @State private var input = "shi"
    @State private var page = 0
    private let engine = CandidateEngine()
    private let pageSize = 8

    private var candidates: [InputCandidate] {
        engine.candidates(for: input, languages: settings.enabledLanguages, learning: personalization.rankingProfile,
                          dictionary: dictionary.dictionaryForInput)
    }

    var body: some View {
        TextField("Type English or Pinyin", text: $input)
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("Candidate preview input")
            .onChange(of: input) { page = 0 }
            .onChange(of: settings.enabledLanguages) { page = 0 }
        let results = candidates
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
}
