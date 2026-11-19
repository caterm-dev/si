import Testing
@testable import SICore

struct CandidateShortlistLimitTests {
    @Test func correctionAfterTheConstructedHeadRemainsSelectable() {
        let ordinary = (0..<6).map {
            InputCandidate(text: "Sentence \($0)", language: .simplifiedChinese, score: 100 - $0,
                           lexicalTokenCount: 2)
        }
        let correction = InputCandidate(text: "你好世界", language: .simplifiedChinese, score: 80,
                                        lexicalTokenCount: 2, isPinyinCorrection: true)
        let literal = InputCandidate(text: "nihoashijie", language: nil, score: 0)
        let ranked = ordinary + [correction, literal]
        #expect(CandidateShortlist.candidates(from: ranked) == Array(ordinary.prefix(4)) + [correction, literal])
    }

    @Test(arguments: InputLanguage.allCases)
    func singleEntryCompletionsShareTheConstructedHead(language: InputLanguage) {
        let completions = (0..<7).map {
            InputCandidate(text: "Completion \($0)", language: language, score: 100 - $0,
                           hasCompletion: true, lexicalTokenCount: 1)
        }
        let word = InputCandidate(text: "Exact", language: language, score: 110, lexicalTokenCount: 1)
        let literal = InputCandidate(text: "source", language: nil, score: 0)
        let ranked = [word] + completions + [literal]
        #expect(CandidateShortlist.candidates(from: ranked) == [word] + Array(completions.prefix(3)) + [literal])
    }

    @Test func nineWordsShareOneBudgetWhileCharactersRemainPageable() {
        let words = (0..<15).map {
            InputCandidate(text: "Word \($0)", language: $0.isMultiple(of: 2) ? .english : .simplifiedChinese,
                           score: 100 - $0, consumedInputCount: $0.isMultiple(of: 3) ? 3 : nil,
                           lexicalTokenCount: 1)
        }
        let characters = (0..<35).map {
            InputCandidate(text: String(UnicodeScalar(0x4E00 + $0)!), language: .simplifiedChinese,
                           score: 200 - $0, consumedInputCount: 1, lexicalTokenCount: 1)
        }
        let literal = InputCandidate(text: "source", language: nil, score: 0)
        let ranked = Array(characters.prefix(20)) + words + Array(characters.dropFirst(20)) + [literal]
        let expected = Array(characters.prefix(20)) + Array(words.prefix(9)) + Array(characters.dropFirst(20)) + [literal]
        #expect(CandidateShortlist.candidates(from: ranked) == expected)
        #expect(CandidateShortlist.candidates(from: expected) == expected)
    }

    @Test func singleCharacterCompletionCannotBypassTheConstructedLimit() {
        let head = (0..<4).map {
            InputCandidate(text: "Sentence \($0)", language: .english, score: 100 - $0, lexicalTokenCount: 2)
        }
        let completion = InputCandidate(text: "字", language: .simplifiedChinese, score: 90,
                                        hasCompletion: true, lexicalTokenCount: 1)
        let literal = InputCandidate(text: "s", language: nil, score: 0)
        #expect(CandidateShortlist.candidates(from: head + [completion, literal]) == head + [literal])
    }
}
