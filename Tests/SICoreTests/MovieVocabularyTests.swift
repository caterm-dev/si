import Testing
@testable import SICore

struct MovieVocabularyTests {
    @Test func titlesKeepSpacesPunctuationNumbersAndCaseThroughDirectLookup() {
        let provider = EnglishCandidateProvider()
        for (input, text) in [("insideouttwo", "Inside Out 2"),
                              ("avengersendgame", "Avengers: Endgame"),
                              ("dontlookup", "Don't Look Up"), ("walle", "WALL-E"),
                              ("pegasusthree", "Pegasus 3"),
                              ("bladerunnertwozerofournine", "Blade Runner 2049")] {
            let values = provider.candidates(for: input)
            #expect(values.contains { $0.text == text && !$0.hasCompletion && $0.language == .english })
            #expect(provider.candidates(for: input.uppercased())
                .contains { $0.text == text.uppercased() && !$0.hasCompletion })
        }
        #expect(provider.candidates(for: "insideout").contains { $0.text == "Inside Out 2" && $0.hasCompletion })
    }

    @Test func titleAndOrdinaryWordWithSameTypingKeyRemainAvailable() throws {
        var node = 0
        for byte in "soulmate".utf8 { node = try #require(EnglishLexicon.advance(node, byte: byte)) }
        #expect(Set(EnglishLexicon.exactMatches(at: node).map(\.text)) == ["soulmate", "Soul Mate"])
        // The local editorial title weight (10) exceeds the upstream word weight (5).
        #expect(EnglishLexicon.exactMatch(at: node)?.text == "Soul Mate")
        #expect(!EnglishLexicon.completions(at: node).contains { $0.key == "soulmate" })
        #expect(!EnglishLexicon.previewCompletions(at: node).contains { $0.key == "soulmate" })
        let values = EnglishCandidateProvider().candidates(for: "soulmate")
        #expect(values.contains { $0.text == "soulmate" && !$0.hasCompletion })
        #expect(values.contains { $0.text == "Soul Mate" && !$0.hasCompletion })
    }

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

    @Test func englishTypingKeysValidateBeforeTrieConstruction() {
        #expect(EnglishLexicon.reading(for: "Don't Look Up") == "dontlookup")
        #expect(EnglishLexicon.reading(for: "Blade Runner 2049") == "bladerunnertwozerofournine")
        #expect(EnglishLexicon.reading(for: "GitHub") == "github")
        for value in [" title", "title ", "line\nbreak", "café", "123", "", String(repeating: "a", count: 65)] {
            #expect(EnglishLexicon.reading(for: value) == nil)
        }
    }
}
