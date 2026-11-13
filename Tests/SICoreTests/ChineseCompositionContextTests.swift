import Foundation
import Testing
@testable import SICore

struct ChineseCompositionContextTests {
    @Test func confirmingAPrefixStartsANewIndependentComposition() throws {
        var session = InputSession()
        let standalone = try #require(CandidateEngine().candidates(for: "shihou", languages: [.simplifiedChinese])
            .first { $0.text == "时候" && !$0.isPartial })
        session.configure(languages: [.simplifiedChinese])
        session.append("nihaoshihou")
        let greeting = try #require(session.candidates.first { $0.text == "你好" && $0.consumedInputCount == 5 })
        let commit = session.commitResult(greeting, reason: .explicitSelection)
        #expect(commit.text == "你好" && session.buffer == "shihou")
        let time = try #require(session.candidates.first { $0.text == "时候" && !$0.isPartial })
        #expect(time.rankingScore == standalone.rankingScore)
        #expect(time.sourceSegmentBoundaries == standalone.sourceSegmentBoundaries)
    }

}
