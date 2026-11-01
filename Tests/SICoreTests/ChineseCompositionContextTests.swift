import Foundation
import Testing
@testable import SICore

struct ChineseCompositionContextTests {
    @Test func directWordsUseDictionaryFrequency() throws {
        let engine = CandidateEngine()
        for enabled: Set<InputLanguage> in [[.simplifiedChinese], Set(InputLanguage.allCases)] {
            let values = engine.candidates(for: "shihou", languages: enabled)
            let time = try #require(values.first { $0.text == "时候" && !$0.isPartial })
            let afterward = try #require(values.first { $0.text == "事后" && !$0.isPartial })
            let timeContext = CandidateLanguageBoundary.chinese()
            let afterContext = CandidateLanguageBoundary.chinese()
            #expect(time.languageBoundary == timeContext && afterward.languageBoundary == afterContext)
            let expected = 1.05 * log2(90_573.0 / 16_616)
            #expect(abs(time.rankingScore - afterward.rankingScore - expected) < 1e-10)
            #expect(values.last?.text == "shihou" && values.last?.isLiteral == true)
        }
    }

    @Test func confirmingAPrefixStartsANewIndependentComposition() throws {
        var session = InputSession()
        session.configure(languages: [.simplifiedChinese])
        session.append("nihaoshihou")
        let greeting = try #require(session.candidates.first { $0.text == "你好" && $0.consumedInputCount == 5 })
        let commit = session.commitResult(greeting, reason: .explicitSelection)
        #expect(commit.text == "你好" && session.buffer == "shihou")
        let time = try #require(session.candidates.first { $0.text == "时候" && !$0.isPartial })
        #expect(time.languageBoundary == CandidateLanguageBoundary.chinese())
    }

    @Test func chineseSentencesUseOnlyWordSpellingAndLanguageCosts() throws {
        let values = PinyinDecoder.standard.candidates(for: "nengxiangbanfayouhuama")
        let sentence = try #require(values.first { ($0.lexicalTokenCount ?? 0) >= 3 })
        var costs: [Double] = []
        var trace = sentence.sourceTrace
        while let node = trace { costs.append(node.lexicalCost); trace = node.previous }
        let expected = -costs.reduce(0, +) - CandidateScoring.initialLanguageCost
            - Double(costs.count - 1) * CandidateScoring.languageCost(previous: 1, next: 1)
        #expect(abs(sentence.rankingScore - expected) < 1e-10)
        #expect(sentence.languageBoundary == .chinese())
    }
}
