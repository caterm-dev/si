import Foundation
import Testing
@testable import SICore

struct PrefixConfirmationTests {
    @Test func exactChineseWordAndEnglishPrefixesCompeteByConsumedSpellingInBothSearchStages() throws {
        let engine = CandidateEngine()
        for languages: Set<InputLanguage> in [[.simplifiedChinese], Set(InputLanguage.allCases)] {
            var session = InputSession(engine: engine, candidateGeneration: .deferred)
            session.configure(languages: languages)
            session.append("dayin")
            let request = try #require(session.pendingCandidateRequest)
            for result in [request.generatePreview(), request.generate()] {
                #expect(session.accept(result) == true)
                let candidates = result.candidates
                let index = try #require(candidates.firstIndex {
                    $0.text == "打印" && $0.language == .simplifiedChinese && !$0.isPartial && !$0.hasCompletion
                })
                let word = candidates[index]
                let prefixes = candidates.filter(\.isPartial)
                #expect(!prefixes.isEmpty)
                #expect(prefixes.allSatisfy { $0.inputScore == $0.rankingScore })
                #expect(word.inputScore == word.rankingScore)
                let shortlist = CandidateShortlist.candidates(from: candidates)
                let visibleIndex = try #require(shortlist.firstIndex { $0.id == word.id })
                #expect(visibleIndex < 5)
                let ordinary = shortlist.filter { !$0.isLiteral }
                for (left, right) in zip(ordinary, ordinary.dropFirst()) {
                    let leftCount = left.consumedInputCount ?? session.buffer.count
                    let rightCount = right.consumedInputCount ?? session.buffer.count
                    #expect(leftCount >= rightCount)
                    if leftCount == rightCount {
                        #expect(session.presentationScore(for: left) >= session.presentationScore(for: right))
                    }
                }
                if languages.contains(.english) {
                    #expect(candidates.contains { $0.text == "day in" && $0.language == .english && !$0.isPartial })
                    #expect(prefixes.contains { $0.text == "day" && $0.consumedInputCount == 3 })
                    #expect(prefixes.contains { $0.text == "day I" && $0.consumedInputCount == 4 })
                }
                #expect(candidates.last?.isLiteral == true && candidates.last?.text == "dayin")
            }
        }
    }
}
