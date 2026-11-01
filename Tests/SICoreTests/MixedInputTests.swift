import Testing
@testable import SICore

struct MixedInputTests {
    private let engine = CandidateEngine()
    private let languages = Set(InputLanguage.allCases)

    @Test func continuousMixedInputWorksInBothDirections() {
        for (input, expected) in [("nihaoworld", "你好 world"), ("hellozhongwen", "hello 中文"),
                                  ("woaiSwift", "我爱 Swift"), ("nihaoWORLD", "你好 WORLD")] {
            let candidates = engine.candidates(for: input, languages: languages)
            #expect(candidates.contains { $0.text == expected && $0.isMixed })
            #expect(candidates.last?.text == input)
            #expect(candidates.last?.isLiteral == true)
        }
    }

    @Test func interleavedChineseAndEnglishAreComposed() {
        #expect(engine.candidates(for: "woaiSwiftshurufa", languages: languages)
            .contains { $0.text == "我爱 Swift 输入法" })
    }

    @Test func mixedSuggestionsRequireBothLanguages() {
        for enabled: Set<InputLanguage> in [[], [.english], [.simplifiedChinese]] {
            #expect(!engine.candidates(for: "nihaoworld", languages: enabled).contains { $0.isMixed })
        }
    }

    @Test func pureEnglishIsNotRelabelledAsMixed() {
        let candidates = engine.candidates(for: "world", languages: languages)
        #expect(candidates.first { !$0.isPartial }?.text == "world")
        #expect(candidates.first { !$0.isPartial }?.language == .english)
        #expect(candidates.first { !$0.isPartial }?.isMixed == false)
    }

    @Test func spacesFollowTheFinalPartOfTheCandidate() throws {
        let mixedEndingEnglish = try #require(engine.candidates(for: "nihaoworld", languages: languages)
            .first { $0.text == "你好 world" })
        let mixedEndingChinese = try #require(engine.candidates(for: "hellozhongwen", languages: languages)
            .first { $0.text == "hello 中文" })
        #expect(mixedEndingEnglish.appendsSpaceOnAcceptance)
        #expect(!mixedEndingChinese.appendsSpaceOnAcceptance)
        #expect(mixedEndingEnglish.label == "Chinese + English")
    }

    @Test func uppercaseEnglishAndTitleCaseArePreserved() {
        let provider = EnglishCandidateProvider()
        #expect(provider.candidates(for: "WORLD").first?.text == "WORLD")
        #expect(provider.candidates(for: "Wor").contains { $0.text == "World" })
    }

    @Test func candidateIdentitiesRemainUniqueAndRepeatable() {
        let candidates = engine.candidates(for: "nihaoworld", languages: languages)
        #expect(Set(candidates.map(\.id)).count == candidates.count)
        #expect(candidates == engine.candidates(for: "nihaoworld", languages: languages))
    }
}
