import Foundation
import Testing
@testable import SICore

struct ChineseMigrationTests {
    @Test func fullSpellingSuppliesTheReportedWholeSentence() {
        for source in ["jintianjiushi", "jin'tian'jiu'shi"] {
            let values = CandidateEngine().candidates(for: source, languages: [.simplifiedChinese])
            #expect(values.first { !$0.isPartial }?.text == "今天就是" && values.first { !$0.isPartial }?.isPartial == false)
            #expect(values.last?.text == source && values.last?.isLiteral == true)
        }
    }
    @Test func exactNeRemainsAvailableWhileEnglishCompletionsCompeteByScore() {
        let engine = CandidateEngine()
        for languages: Set<InputLanguage> in [[.simplifiedChinese], Set(InputLanguage.allCases)] {
            let values = engine.candidates(for: "ne", languages: languages)
            #expect(values.contains { $0.text == "呢" && !$0.hasCompletion })
            if !languages.contains(.english) { #expect(values.first?.text == "呢") }
            #expect(values.last?.text == "ne" && values.last?.isLiteral == true)
            if languages.contains(.english) { #expect(values.contains { $0.text == "new" }) }
            #expect(values == engine.candidates(for: "ne", languages: languages))
        }
    }

    @Test func evidenceLeavesVisibleCandidatesAndScoresUnchanged() {
        let engine = CandidateEngine()
        for source in ["nihaopengyou", "julitebieyuan", "womenxuexizhongwen", "shi" + String(repeating: "shi", count: 19)] {
            let plain = engine.candidates(for: source, languages: [.simplifiedChinese])
            let traced = engine.candidates(for: source, languages: [.simplifiedChinese], includesConfirmationEvidence: true)
            #expect(plain.map(\.id) == traced.map(\.id))
            #expect(plain.map(\.rankingScore) == traced.map(\.rankingScore))
            #expect(plain.map { Array($0.text.utf8) } == traced.map { Array($0.text.utf8) })
            #expect(traced.allSatisfy { $0.confirmationBoundaries.count <= 8 })
        }
    }

}
