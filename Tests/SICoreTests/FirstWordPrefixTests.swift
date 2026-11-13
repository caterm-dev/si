import Foundation
import Testing
@testable import SICore

struct FirstWordPrefixTests {
    @Test func fourConstructedChoicesLeaveTheRemainingSlotsForRankedWords() {
        let sentence = InputCandidate(text: "完整句子", language: .simplifiedChinese, score: 100)
        let fragments = (0..<40).map {
            InputCandidate(text: "长片段\($0)", language: .simplifiedChinese,
                           score: 90 - $0, consumedInputCount: 9, lexicalTokenCount: 3)
        }
        let words = (0..<20).map {
            InputCandidate(text: "词\($0)", language: .simplifiedChinese,
                           score: -$0, consumedInputCount: 3, lexicalTokenCount: 1)
        }
        let english = InputCandidate(text: "word", language: .english, score: -100, lexicalTokenCount: 1)
        let mixed = InputCandidate(text: "中word", language: .simplifiedChinese, score: -101, isMixed: true)
        let literal = InputCandidate(text: "synthetic", language: nil, score: 0)
        let engine = [sentence] + fragments + words + [english, mixed, literal]
        let shortlist = CandidateShortlist.candidates(from: engine)
        #expect(shortlist.count == words.count + 6 && shortlist.count <= CandidateShortlist.ordinaryCandidateLimit)
        #expect(shortlist.first == sentence && shortlist.last == literal)
        #expect(words.prefix(12).allSatisfy(shortlist.contains))
        #expect(shortlist.contains(english) && !shortlist.contains(mixed))
        #expect(shortlist == [sentence] + Array(fragments.prefix(3)) + words + [english, literal])
        #expect(shortlist.filter(\.isLexicalPrefix) == Array(words.prefix(20)))
        #expect(shortlist == CandidateShortlist.candidates(from: engine))

        // Low-scoring mixed fragments do not displace sentence alternatives.
        let readings = (0..<12).map {
            InputCandidate(text: "完整句\($0)", language: .simplifiedChinese, score: 100 - $0)
                .withChineseSentenceOrigin()
        }
        let crowded = CandidateShortlist.candidates(from: readings + fragments + words + [english, mixed, literal])
        #expect(crowded.count == words.count + 6 && crowded.count <= CandidateShortlist.ordinaryCandidateLimit && crowded.last == literal)
        #expect(crowded.filter { $0.isChineseSentence || $0.isMixed }.count == 4)
        #expect(crowded.contains(english) && !crowded.contains(mixed))
        #expect(words.allSatisfy(crowded.contains))
    }

}
