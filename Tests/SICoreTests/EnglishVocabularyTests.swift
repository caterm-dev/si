import Foundation
import Testing
@testable import SICore

struct EnglishVocabularyTests {
    @Test func expandedWordsAndTerminologyAreAvailableWithCaseAndLiteralPreserved() {
        let engine = CandidateEngine()
        for input in ["subtitle", "subtitles", "SUBTITLE", "Subtitle", "SwiftUI", "abandon"] {
            let result = engine.candidates(for: input, languages: [.english])
            #expect(result.contains { $0.text == input && $0.language == .english && !$0.hasCompletion })
            #expect(result.last?.text == input && result.last?.isLiteral == true)
        }
        #expect(!engine.candidates(for: "subtitle", languages: [.simplifiedChinese])
            .contains { $0.language == .english })
    }

    @Test func originalCompletionsRemainAvailableInsideExpandedMixedSearch() {
        let engine = CandidateEngine()
        let languages = Set(InputLanguage.allCases)
        #expect(engine.candidates(for: "nihaowor", languages: languages)
            .contains { $0.text == "你好 world" && !$0.isPartial && $0.hasCompletion })
        #expect(engine.candidates(for: "nihaosubtitle", languages: languages)
            .contains { $0.text == "你好 subtitle" && $0.isMixed && !$0.hasLiteralSegments })
        #expect(engine.candidates(for: "shi", languages: languages).contains { $0.text == "是" })
        #expect(engine.candidates(for: "shi", languages: languages).contains { $0.text == "ship" })
    }
}
