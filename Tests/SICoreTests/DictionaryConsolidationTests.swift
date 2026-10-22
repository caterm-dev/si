import Testing
@testable import SICore

struct DictionaryConsolidationTests {
    @Test func englishVocabularyRemainsAvailableBesideTheMSIMEChineseDictionary() {
        let engine = CandidateEngine()
        for input in ["new", "need", "next"] {
            #expect(EnglishCandidateProvider().candidates(for: input).contains {
                $0.text == input && $0.language == .english && !$0.hasCompletion
            })
            let values = engine.candidates(for: input, languages: Set(InputLanguage.allCases))
            #expect(values.contains { $0.text == input && $0.language == .english })
            #expect(values.last?.text == input && values.last?.isLiteral == true)
        }
        let chinese = engine.candidates(for: "ne", languages: Set(InputLanguage.allCases))
        #expect(chinese.first?.text == "呢" && chinese.first?.language == .simplifiedChinese)
        #expect(chinese.contains { $0.text == "new" && $0.language == .english })
        #expect(chinese.last?.text == "ne" && chinese.last?.isLiteral == true)
    }
}
