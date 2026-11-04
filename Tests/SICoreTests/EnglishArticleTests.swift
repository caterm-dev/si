import Testing
@testable import SICore

struct EnglishArticleTests {
    @Test func articleHasExactEnglishCandidatesWithPreservedCase() {
        let engine = CandidateEngine()
        for input in ["a", "A"] {
            for languages: Set<InputLanguage> in [[.english], Set(InputLanguage.allCases)] {
                let candidates = engine.candidates(for: input, languages: languages)
                #expect(candidates.contains {
                    $0.text == input && $0.language == .english && !$0.isPartial && !$0.hasCompletion
                })
                #expect(candidates.last?.text == input && candidates.last?.isLiteral == true)
            }
        }
    }

    @Test func articleParticipatesInContinuousEnglishSegmentation() {
        let engine = CandidateEngine()
        for input in ["sendaenglish", "send'a'english"] {
            for languages: Set<InputLanguage> in [[.english], Set(InputLanguage.allCases)] {
                let candidates = engine.candidates(for: input, languages: languages)
                #expect(candidates.contains {
                    $0.text == "send a english" && $0.language == .english && !$0.isPartial
                        && !$0.hasCompletion && !$0.hasLiteralSegments
                })
                #expect(candidates.last?.text == input && candidates.last?.isLiteral == true)
            }
            for languages: Set<InputLanguage> in [[], [.simplifiedChinese]] {
                #expect(!engine.candidates(for: input, languages: languages).contains { $0.language == .english })
            }
        }
    }
}
