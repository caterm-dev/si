import Testing
@testable import SICore

struct DomainVocabularyTests {
    @Test func domainCandidatesRespectLanguageSettingsAndExactLiteralInput() {
        let engine = CandidateEngine()
        let input = "google.com"
        for languages: Set<InputLanguage> in [[.english], Set(InputLanguage.allCases)] {
            let values = engine.candidates(for: input, languages: languages)
            #expect(values.contains { $0.text == input && $0.language == .english && !$0.hasCompletion })
            #expect(values.last?.text == input && values.last?.isLiteral == true)
            #expect(values.map(\.id) == engine.candidates(for: input, languages: languages).map(\.id))
            let preview = engine.previewCandidates(for: input, languages: languages, learning: LearningProfile(),
                dictionary: UserDictionary(), now: .now, context: nil)
            #expect(preview.contains { $0.text == input && $0.language == .english && !$0.hasCompletion })
            #expect(preview.last?.text == input && preview.last?.isLiteral == true)
        }
        for languages: Set<InputLanguage> in [[], [.simplifiedChinese]] {
            let values = engine.candidates(for: input, languages: languages)
            #expect(!values.contains { $0.text == input && $0.language == .english })
            #expect(values.last?.text == input && values.last?.isLiteral == true)
        }
        for input in [".ai", "private-host.example", "MyHost.internal"] {
            let values = engine.candidates(for: input, languages: Set(InputLanguage.allCases))
            #expect(values.last?.text == input && values.last?.isLiteral == true)
        }
    }

}
