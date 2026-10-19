import Testing
@testable import SICore

struct CandidateEngineTests {
    private let engine = CandidateEngine()
    private let languages = Set(InputLanguage.allCases)

    @Test func malformedProvidersCannotReviveDisabledLanguagesOrDuplicateLiteralIdentity() {
        let candidates = CandidateEngine(providers: [MalformedProvider()]).candidates(for: "x", languages: [.english])
        #expect(candidates.count == 1)
        #expect(candidates.first?.text == "x" && candidates.first?.isLiteral == true)
    }

    @Test func ambiguousInputKeepsBothLanguagesAndLiteral() {
        let candidates = engine.candidates(for: "shi", languages: languages)
        #expect(candidates.contains { $0.text == "是" && $0.language == .simplifiedChinese })
        #expect(candidates.contains { $0.text == "ship" && $0.language == .english })
        #expect(candidates.last?.text == "shi")
        #expect(candidates.last?.isLiteral == true)
    }

    @Test func exactEnglishMatchDoesNotHideChinese() {
        let candidates = engine.candidates(for: "he", languages: languages)
        #expect(candidates.first?.text == "he")
        #expect(candidates.contains { $0.text == "和" })
        #expect(candidates.contains { $0.text == "喝" })
    }

    @Test func disabledLanguageDoesNotContributeCandidates() {
        let candidates = engine.candidates(for: "shi", languages: [.english])
        #expect(candidates.allSatisfy { $0.language != .simplifiedChinese })
        #expect(candidates.contains { $0.text == "ship" })
        let chineseOnly = engine.candidates(for: "shi", languages: [.simplifiedChinese])
        #expect(chineseOnly.allSatisfy { $0.language != .english })
    }

    @Test func literalSurvivesUnknownInputAndDisabledProviders() {
        for input in ["unknownword", "https://example.com", "camelCase", "123", "👩🏽‍💻"] {
            let candidates = engine.candidates(for: input, languages: [])
            #expect(candidates.count == 1)
            #expect(candidates.first?.text == input)
            #expect(candidates.first?.isLiteral == true)
        }
        #expect(engine.candidates(for: "", languages: languages).isEmpty)
    }

    @Test func pinyinHandlesCaseAndSyllableSeparator() {
        #expect(engine.candidates(for: "Ni'Hao", languages: languages).contains { $0.text == "你好" })
        #expect(engine.candidates(for: "Ni'Hao", languages: languages).last?.text == "Ni'Hao")
    }

    @Test func rankingIsDeterministicAndCandidatesAreUnique() {
        let first = engine.candidates(for: "shi", languages: languages)
        #expect(first == engine.candidates(for: "shi", languages: languages))
        #expect(Set(first.map(\.id)).count == first.count)
        #expect(first.first?.text == "是")
    }

    @Test func deduplicationPreservesDifferentLanguageIdentities() {
        let english = FixedProvider(language: .english)
        let chinese = FixedProvider(language: .simplifiedChinese)
        let engine = CandidateEngine(providers: [english, english, chinese])
        let result = engine.candidates(for: "same", languages: languages)
        #expect(result.count == 3)
        #expect(Set(result.map(\.id)).count == 3)
    }
}

private struct FixedProvider: CandidateProvider {
    let language: InputLanguage
    func candidates(for input: String) -> [InputCandidate] {
        [InputCandidate(text: "same", language: language, score: 100)]
    }
}

private struct MalformedProvider: CandidateProvider {
    let language = InputLanguage.english
    func candidates(for input: String) -> [InputCandidate] {
        [InputCandidate(text: "disabled", language: .simplifiedChinese, score: 999),
         InputCandidate(text: input, language: nil, score: 999),
         InputCandidate(text: "", language: .english, score: 999),
         InputCandidate(text: "invalid mixed", language: .english, score: 999, isMixed: true)]
    }
}
