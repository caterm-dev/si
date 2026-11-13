import Foundation
import Testing
@testable import SICore

struct ChineseSegmentationTests {
    @Test func ambiguousFullSpellingCompetesInPreviewAndFinalSearch() throws {
        for input in ["woxianganzhao", "wo'xiang'an'zhao", "woxiang'anzhao", "wo'woxianganzhao"] {
            let expected = input.hasPrefix("wo'wo") ? "我我想按照" : "我想按照"
            for languages: Set<InputLanguage> in [[.simplifiedChinese], Set(InputLanguage.allCases)] {
                var session = InputSession(candidateGeneration: .deferred)
                session.configure(languages: languages)
                session.append(input)
                let request = try #require(session.pendingCandidateRequest)
                for values in [request.generatePreview().candidates, request.generate().candidates] {
                    #expect(values.contains { $0.text == expected && !$0.isPartial && !$0.hasCompletion })
                    #expect(values.last?.text == input && values.last?.isLiteral == true)
                }
            }
        }
    }

    @Test func evidenceDoesNotChangeAmbiguousResults() {
        let engine = CandidateEngine()
        for input in ["woxianganzhao", "woxianganzhaozhege", "wo'xian'gan'zhao"] {
            let plain = engine.candidates(for: input, languages: [.simplifiedChinese])
            let traced = engine.candidates(for: input, languages: [.simplifiedChinese], includesConfirmationEvidence: true)
            #expect(plain.map(\.id) == traced.map(\.id))
            #expect(plain.map(\.rankingScore) == traced.map(\.rankingScore))
        }
    }

}
