import SwiftUI

struct CandidatePreviewView: View {
    let settings: LanguageSettings
    @State private var input = "shi"
    private let engine = CandidateEngine()

    var body: some View {
        TextField("Type English or Pinyin", text: $input)
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("Candidate preview input")
        ForEach(engine.candidates(for: input, languages: settings.enabledLanguages)) { candidate in
            HStack {
                Text(candidate.text).font(.body.monospaced())
                Spacer()
                Text(candidate.label).font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
        if settings.enabledLanguages.isEmpty {
            Text("No languages are enabled. SI will keep text as typed.").foregroundStyle(.secondary)
        }
    }
}
