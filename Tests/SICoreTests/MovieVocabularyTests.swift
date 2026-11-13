import Testing
@testable import SICore

struct MovieVocabularyTests {
    @Test func movieCandidatesRespectEnabledLanguagesAndLiteralFallback() {
        let engine = CandidateEngine()
        for (input, text, language) in [("feichirenshengsan", "飞驰人生3", InputLanguage.simplifiedChinese),
                                        ("nezhazhimotongnaohai", "哪吒之魔童闹海", .simplifiedChinese),
                                        ("insideouttwo", "Inside Out 2", .english)] {
            for languages: Set<InputLanguage> in [[language], Set(InputLanguage.allCases)] {
                let values = engine.candidates(for: input, languages: languages)
                #expect(values.contains { $0.text == text && $0.language == language }, "Missing title for \(input)")
                #expect(values.last?.text == input && values.last?.isLiteral == true)
                #expect(values.map(\.id) == engine.candidates(for: input, languages: languages).map(\.id))
            }
            let disabled = engine.candidates(for: input, languages: [])
            #expect(disabled.count == 1 && disabled.first?.text == input && disabled.first?.isLiteral == true)
        }
    }

}
