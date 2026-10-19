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

    @Test func indexedPrefixesKeepEveryMatchingWordIncludingLargeResultSets() {
        let provider = EnglishCandidateProvider()
        for prefix in ["a", "sub", "wor", "z", "zzzz", ""] {
            let expected = prefix.isEmpty ? [] : EnglishLexicon.words.filter { $0.lowercased().hasPrefix(prefix) }
            #expect(provider.candidates(for: prefix).map(\.text) == expected)
        }
        #expect(provider.candidates(for: "a").count > 100)
        #expect(provider.candidates(for: "sub").contains { $0.text == "subtitle" && $0.hasCompletion })
        #expect(provider.candidates(for: "sub").contains { $0.text == "subtitles" && $0.hasCompletion })
    }

    @Test func originalCompletionsRemainAvailableInsideExpandedMixedSearch() {
        let engine = CandidateEngine()
        let languages = Set(InputLanguage.allCases)
        #expect(engine.candidates(for: "nihaowor", languages: languages)
            .contains { $0.text == "你好world" && !$0.isPartial && $0.hasCompletion })
        #expect(engine.candidates(for: "nihaosubtitle", languages: languages)
            .contains { $0.text == "你好subtitle" && $0.isMixed && !$0.hasLiteralSegments })
        #expect(engine.candidates(for: "shi", languages: languages).contains { $0.text == "是" })
        #expect(engine.candidates(for: "shi", languages: languages).contains { $0.text == "ship" })
    }
}
