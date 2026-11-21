import Testing
@testable import SICore

struct CandidateShortlistLimitTests {
    @Test func statisticalLeadersStaySelectableInRerankedOrder() {
        let head = (0..<4).map {
            InputCandidate(text: "Completion \($0)", language: .english, score: -40 - $0,
                           hasCompletion: true, lexicalTokenCount: 2, modelRankingScore: 1)
                .withPresentationScore(10 - Double($0), remembered: false, statisticalScore: -40 - Double($0))
        }
        let lower = InputCandidate(text: "Lower sentence", language: .english, score: -35,
                                   lexicalTokenCount: 2, modelRankingScore: 0.5)
            .withPresentationScore(15, remembered: false, statisticalScore: -35)
        let second = InputCandidate(text: "限定个", language: .simplifiedChinese, score: -30,
                                    lexicalTokenCount: 2, modelRankingScore: 0.3)
            .withPresentationScore(20, remembered: false, statisticalScore: -30)
        let first = InputCandidate(text: "先定个", language: .simplifiedChinese, score: -25,
                                   lexicalTokenCount: 2, modelRankingScore: 0.2)
            .withPresentationScore(25, remembered: false, statisticalScore: -25)
        let literal = InputCandidate(text: "xiandingge", language: nil, score: 0)
        #expect(CandidateShortlist.candidates(from: head + [lower, second, first, literal])
            == head + [second, first, literal])
    }

    @Test func protectedWordsCountTowardTheOrdinaryWordBudget() {
        let words = (0..<12).map {
            InputCandidate(text: "Word \($0)", language: .english, score: $0,
                           lexicalTokenCount: 1, modelRankingScore: Double(12 - $0))
                .withPresentationScore(Double($0), remembered: false, statisticalScore: Double($0))
        }
        let literal = InputCandidate(text: "source", language: nil, score: 0)
        let expected = Array(words.prefix(7)) + Array(words.suffix(2)) + [literal]
        #expect(CandidateShortlist.candidates(from: words + [literal]) == expected)
    }

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
