import Foundation
import Testing
@testable import SICore

struct TerminalRankingTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func standardIncompleteSpellingKeepsTheStrongestDerivationAndCompletionFlag() throws {
        let engine = CandidateEngine()
        let languages = Set(InputLanguage.allCases)
        let original = engine.candidates(for: "niha", languages: languages, now: now)
        let greeting = try #require(original.first { $0.text == "你好" && !$0.isPartial })
        #expect(greeting.rankingScore.isFinite)
        #expect(greeting.hasCompletion)
        var profile = LearningProfile()
        profile.record(InputCommit(input: "niha", candidate: greeting, reason: .explicitSelection), now: now)
        let learned = engine.candidates(for: "niha", languages: languages, learning: profile, now: now)
        #expect(learned.first?.text == "你好")
        #expect(learned.first?.hasCompletion == true)
        #expect(learned.last?.text == "niha" && learned.last?.isLiteral == true)
    }
}
