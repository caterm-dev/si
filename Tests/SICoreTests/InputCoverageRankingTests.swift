import Testing
@testable import SICore

struct InputCoverageRankingTests {
    @Test(arguments: ["mingtianwomenqubeijing", "ming'tian'wo'men'qu'bei'jing",
                      "zhegeshurufakeyishuruzhongwenheyingwen", "iwanttobuild"])
    func continuousCompositionLeadsBothStagesAndDefaultAcceptanceConsumesTheWholeInput(input: String) throws {
        let expected = input.hasPrefix("ming") ? "明天我们去北京"
            : input.hasPrefix("zhege") ? "这个输入法可以输入中文和英文"
            : "I want to build"
        let singleLanguage: Set<InputLanguage> = input.hasPrefix("iwant") ? [.english] : [.simplifiedChinese]
        for languages in [singleLanguage, Set(InputLanguage.allCases)] {
            var session = InputSession(candidateGeneration: .deferred)
            session.configure(languages: languages)
            session.append(input)
            let request = try #require(session.pendingCandidateRequest)
            for result in [request.generatePreview(), request.generate()] {
                #expect(session.accept(result) == true)
                let first = try #require(session.candidates.first)
                #expect(first.text == expected && !first.isPartial)
                #expect(CandidateShortlist.candidates(from: session.candidates).first?.id == first.id)
                #expect(session.candidates.last?.isLiteral == true && session.candidates.last?.text == input)
            }
            let commit = session.commitResult(session.candidates.first, reason: .defaultAcceptance)
            #expect(commit.text == expected && commit.input == input)
            #expect(commit.remainingInput.isEmpty && session.buffer.isEmpty && session.candidates.isEmpty)
        }
    }

    @Test func mixedSentenceIsVisibleWithoutRequiringItToOutrankEveryStrongPrefix() throws {
        for preview in [true, false] {
            var session = InputSession(candidateGeneration: .deferred)
            session.append("woxiangyaodeploy")
            let request = try #require(session.pendingCandidateRequest)
            #expect(session.accept(preview ? request.generatePreview() : request.generate()) == true)
            let choices = CandidateShortlist.candidates(from: session.candidates)
            let index = try #require(choices.firstIndex { $0.text == "我想要 deploy" && !$0.isPartial })
            #expect(index < 5)
            let commit = session.commitResult(choices[index], reason: .explicitSelection)
            #expect(commit.text == "我想要 deploy" && commit.input == "woxiangyaodeploy")
            #expect(commit.remainingInput.isEmpty && session.buffer.isEmpty)
        }
    }

    @Test func sameSourceCoverageDoesNotRewardMoreWordsOrLongerPredictedOutput() {
        let word = InputCandidate(text: "word", language: .english, score: -10, lexicalTokenCount: 1)
        let split = InputCandidate(text: "many small words", language: .english, score: -10, lexicalTokenCount: 3)
        let completion = InputCandidate(text: String(repeating: "long prediction ", count: 50), language: .english,
                                        score: -10, hasCompletion: true, lexicalTokenCount: 1)
        var session = InputSession(candidateGeneration: .deferred)
        session.append("abcdef")
        #expect(session.presentationScore(for: word) == 20)
        #expect(session.presentationScore(for: split) == 20)
        #expect(session.presentationScore(for: completion) == 20)
    }

    @Test func separatorsUmlautAliasesAndCaseDoNotInflateCoverage() {
        let word = InputCandidate(text: "绿色", language: .simplifiedChinese, score: -10)
        for spelling in ["lvse", "lü'se'", "lu:'se'", "LÜ'SE'"] {
            var session = InputSession(candidateGeneration: .deferred)
            session.append(spelling)
            #expect(session.presentationScore(for: word) == 10)
        }
    }

    @Test func verbatimOutputAndPunctuationDoNotCreateMatchedLetters() {
        let literal = InputCandidate(text: "ABC.123", language: nil, score: 0)
        let verbatim = InputCandidate(text: "中 unknown", language: .simplifiedChinese, score: -10,
                                      isMixed: true, hasLiteralSegments: true)
        let domain = InputCandidate(text: "abc.123", language: .english, score: -10)
        var session = InputSession(candidateGeneration: .deferred)
        session.append("ABC.123")
        #expect(session.presentationScore(for: literal) == 0)
        #expect(session.presentationScore(for: verbatim) == -10)
        #expect(session.presentationScore(for: domain) == 20)

        let punctuation = InputCandidate(text: "，", language: .simplifiedChinese, score: 0,
                                         punctuationLanguage: .simplifiedChinese)
        session.reset()
        session.append(",")
        #expect(session.presentationScore(for: punctuation) == 0)
    }

    @Test func punctuationVariantsReceiveCoverageOnceWithoutChangingLexicalScores() throws {
        for preview in [true, false] {
            var session = InputSession(candidateGeneration: .deferred)
            session.configure(languages: [.simplifiedChinese], punctuationCandidatesEnabled: true)
            session.append("nihao,")
            let request = try #require(session.pendingCandidateRequest)
            #expect(session.accept(preview ? request.generatePreview() : request.generate()) == true)
            let punctuated = try #require(session.candidates.first { $0.text == "你好，" && $0.isPunctuation })
            let word = try #require(CandidateEngine().candidates(for: "nihao", languages: [.simplifiedChinese])
                .first { $0.text == "你好" && !$0.isPartial })
            #expect(punctuated.rankingScore == word.rankingScore)
            #expect(session.presentationScore(for: punctuated) == word.rankingScore + 25)
            let commit = session.commitResult(punctuated, reason: .explicitSelection)
            #expect(commit.text == "你好，" && commit.input == "nihao," && session.buffer.isEmpty)
            #expect(commit.candidate?.canLearn == false && commit.candidate?.appendsSpaceOnAcceptance == false)
        }
    }
}
