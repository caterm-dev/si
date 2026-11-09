import Foundation
import Testing
@testable import SICore

struct ChineseSentenceAlternativesTests {
    @Test func reportedSentenceRemainsInEngineWhileWindowLimitsConstructedChoices() throws {
        for input in ["erbeizuoduo", "er'bei'zuo'duo"] {
            for languages: Set<InputLanguage> in [[.simplifiedChinese], Set(InputLanguage.allCases)] {
                var session = InputSession(candidateGeneration: .deferred)
                session.configure(languages: languages)
                session.append(input)
                let request = try #require(session.pendingCandidateRequest)
                for result in [request.generatePreview(), request.generate()] {
                    let sentence = try #require(result.candidates.first { $0.text == "二倍做多" && !$0.isPartial })
                    #expect(sentence.isChineseSentence)
                    let visible = CandidateShortlist.candidates(from: result.candidates)
                    #expect(visible.filter { $0.lexicalTokenCount != 1 && !$0.isLiteral }.count <= 4)
                    #expect(visible.first?.id == result.candidates.first?.id)
                    #expect(visible.last?.isLiteral == true && visible.last?.text == input)
                    let accepted = session.accept(result)
                    #expect(accepted)
                }
                let chosen = try #require(session.candidates.first { $0.text == "二倍做多" && !$0.isPartial })
                let commit = session.commitResult(chosen, reason: .explicitSelection)
                #expect(commit.text == "二倍做多" && commit.input == input && session.buffer.isEmpty)
            }
        }
    }

    @Test func decoderEmitsThirtyTwoDistinctBoundedSentencesWithoutChangingEvidenceResults() {
        let decoder = PinyinDecoder(entries: ["是", "时", "事", "市", "十", "使", "试", "式"].enumerated().map {
            PinyinLexiconEntry(syllables: ["shi"], text: $0.element, upstreamWeight: UInt64(1_000 - $0.offset * 50))
        })
        for preview in [false, true] {
            let plain = decoder.compositionCandidates(for: "shishishi", languages: [.simplifiedChinese], preview: preview)
            let sentences = plain.filter { !$0.isPartial }
            #expect(sentences.count == 32 && Set(sentences.map(\.id)).count == 32)
            #expect(sentences.allSatisfy { $0.isChineseSentence })
            #expect(plain == decoder.compositionCandidates(for: "shishishi", languages: [.simplifiedChinese], preview: preview))
            let traced = decoder.compositionCandidates(for: "shishishi", languages: [.simplifiedChinese],
                preview: preview, includesConfirmationEvidence: true)
            #expect(plain.map(\.id) == traced.map(\.id))
            #expect(plain.map(\.rankingScore) == traced.map(\.rankingScore))
        }
    }

    @Test func reportedHomophoneSentenceSurvivesBeforeLanguageModelReranking() {
        let engine = CandidateEngine()
        for input in ["zhaojichujuzi", "zhao'ji'chu'ju'zi"] {
            for languages: Set<InputLanguage> in [[.simplifiedChinese], Set(InputLanguage.allCases)] {
                for candidates in [engine.previewCandidates(for: input, languages: languages, learning: LearningProfile(),
                                                            dictionary: UserDictionary(), now: .now, context: nil),
                                   engine.candidates(for: input, languages: languages)] {
                    #expect(candidates.contains { $0.text == "找几处句子" && !$0.isPartial })
                    #expect(candidates.last?.isLiteral == true && candidates.last?.text == input)
                }
            }
        }
    }

    @Test func directLexicalMatchesDoNotAcquireSentencePlacementFromDuplicatePaths() throws {
        let decoder = PinyinDecoder(entries: [
            PinyinLexiconEntry(syllables: ["ni"], text: "你", upstreamWeight: 100),
            PinyinLexiconEntry(syllables: ["hao"], text: "好", upstreamWeight: 100),
            PinyinLexiconEntry(syllables: ["ni", "hao"], text: "你好", upstreamWeight: 10_000),
        ])
        let greeting = try #require(decoder.candidates(for: "nihao").first { $0.text == "你好" })
        #expect(!greeting.isChineseSentence && greeting.lexicalTokenCount == 1)
        let generated = sentence("甲乙丙", score: 10)
        let direct = InputCandidate(text: "甲乙丙", language: .simplifiedChinese, score: 9, lexicalTokenCount: 1)
        for (var retained, other) in [(generated, direct), (direct, generated)] {
            retained.retainLexicalEvidence(from: other)
            #expect(!retained.isChineseSentence && retained.lexicalTokenCount == 1)
        }
        #expect(generated.id == direct.id && generated.hasSameCommitValue(as:
            InputCandidate(text: "甲乙丙", language: .simplifiedChinese, score: 10)))
    }

    @Test func personalizedAlternativesKeepTheBaseLaneAndStayBounded() {
        let decoder = PinyinDecoder(entries: ["是", "时", "事", "市"].enumerated().map {
            PinyinLexiconEntry(syllables: ["shi"], text: $0.element, upstreamWeight: UInt64(1_000 - $0.offset * 50))
        })
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let learning = LearningProfile(entries: [
            LearnedPreference(input: "shishishi", text: "时时时", language: .simplifiedChinese, strength: 8, lastUsed: now),
        ], now: now)
        let base = decoder.candidates(for: "shishishi")
        let personalized = decoder.compositionCandidates(for: "shishishi", languages: [.simplifiedChinese],
            learning: learning, now: now, includesPartials: false)
        #expect(personalized.first?.text == "时时时")
        #expect(base.allSatisfy { original in personalized.contains { $0.id == original.id } })
        #expect(personalized.count <= 64 && Set(personalized.map(\.id)).count == personalized.count)
    }

    @Test func rankedHeadIncludesWordsWithoutBackfillingLowerHypotheses() {
        let readings = ["甲乙丙", "甲乙丁", "甲乙戊", "甲乙己", "甲乙庚", "甲乙辛"]
            .enumerated().map { sentence($0.element, score: 99 - $0.offset * 10) }
        let word = InputCandidate(text: "甲", language: .simplifiedChinese, score: 95,
                                  consumedInputCount: 1, lexicalTokenCount: 1)
        let english = InputCandidate(text: "word", language: .english, score: 1, lexicalTokenCount: 1)
        let literal = InputCandidate(text: "synthetic", language: nil, score: 0)
        let input = [readings[0], word] + Array(readings.dropFirst()) + [english, literal]
        let result = CandidateShortlist.candidates(from: input)
        #expect(result == [readings[0], word, readings[1], readings[2], english, literal])
        #expect(result.map(\.rankingScore) == [99, 95, 89, 79, 1, 0])
    }

    @Test func fewerThanFourReadingsDoNotDuplicateOrBackfillTheLeadingGroup() {
        let readings = ["甲乙", "甲丙", "甲丁"].map { sentence($0, score: 10) }
        let word = InputCandidate(text: "词语", language: .simplifiedChinese, score: 9, lexicalTokenCount: 1)
        let literal = InputCandidate(text: "synthetic", language: nil, score: 0)
        #expect(CandidateShortlist.candidates(from: readings + [word, literal]) == readings + [word, literal])
    }

    @Test func rankedHeadKeepsPinsWithoutReservingLanguagesOrPromotingFragments() {
        let pin = InputCandidate(text: "固定", language: .simplifiedChinese, score: 100, isUserPhrase: true, isPreferred: true)
        let readings = ["甲乙丙", "甲乙丁", "甲乙戊", "甲乙己", "甲乙庚", "甲乙辛"].map { sentence($0, score: 90) }
        let words = (0..<50).map { InputCandidate(text: "词\($0)", language: .simplifiedChinese, score: 80, lexicalTokenCount: 1) }
        let english = InputCandidate(text: "word", language: .english, score: 1, lexicalTokenCount: 1)
        let mixed = InputCandidate(text: "甲word", language: .simplifiedChinese, score: 1, isMixed: true)
        let literal = InputCandidate(text: "synthetic", language: nil, score: 0)
        let result = CandidateShortlist.candidates(from: [pin, readings[0]] + words + Array(readings.dropFirst()) + [english, mixed, literal])
        #expect(result.count == 27 && result.first == pin && result.last == literal)
        #expect(result.contains(readings[0]))
        #expect(!readings.dropFirst().contains(where: result.contains))
        #expect(!result.contains(english) && !result.contains(mixed))
        #expect(result == [pin, readings[0]] + Array(words.prefix(24)) + [literal])
        #expect(result.filter { $0.isChineseSentence || $0.isMixed }.count == 1)
    }

    @Test(arguments: InputLanguage.allCases)
    func anotherLanguagesFirstSentenceAndCompleteWordDoNotDisplaceHigherRankedChoices(language: InputLanguage) {
        let other: InputLanguage = language == .english ? .simplifiedChinese : .english
        let leaders = (0..<4).map {
            InputCandidate(text: "Sentence \($0)", language: language, score: 100 - $0, lexicalTokenCount: 2)
        }
        let words = (0..<30).map {
            InputCandidate(text: "Word \($0)", language: language, score: 90 - $0, lexicalTokenCount: 1)
        }
        let otherSentence = InputCandidate(text: "Other sentence", language: other, score: 0, lexicalTokenCount: 2)
        let otherWord = InputCandidate(text: "Other", language: other, score: -1, lexicalTokenCount: 1)
        let literal = InputCandidate(text: "SyntheticInput", language: nil, score: 0)
        let ranked = leaders + words + [otherSentence, otherWord, literal]
        let shortlist = CandidateShortlist.candidates(from: ranked)
        #expect(shortlist == leaders + Array(words.prefix(22)) + [literal])
        #expect(CandidateShortlist.candidates(from: ranked) == shortlist)
        let higherWord = InputCandidate(text: otherWord.text, language: other, score: 99,
            rankingScore: 99.5, lexicalTokenCount: 1)
        let competitive = [leaders[0], higherWord] + Array(leaders.dropFirst()) + words + [literal]
        #expect(CandidateShortlist.candidates(from: competitive).prefix(2) == [leaders[0], higherWord])
    }

    @Test func mixedChoicesCompeteForTheRankedHeadWithoutAReservation() {
        let readings = (0..<4).map { sentence("组合\($0)", score: 100 - $0) }
        let english = InputCandidate(text: "word", language: .english, score: 1, lexicalTokenCount: 1)
        let literal = InputCandidate(text: "synthetic", language: nil, score: 0)
        for completion in [false, true] {
            let mixed = InputCandidate(text: "中 word", language: .simplifiedChinese, score: 95,
                                       isMixed: true, hasCompletion: completion, lexicalTokenCount: 2)
            let lowerRanked = readings + [mixed, english, literal]
            #expect(CandidateShortlist.candidates(from: lowerRanked) == readings + [english, literal])
            let higherMixed = InputCandidate(text: mixed.text, language: mixed.language, score: 101,
                                             isMixed: true, hasCompletion: completion, lexicalTokenCount: 2)
            let higherRanked = [higherMixed] + readings + [english, literal]
            #expect(CandidateShortlist.candidates(from: higherRanked)
                == [higherMixed] + Array(readings.prefix(3)) + [english, literal])
        }
    }

    private func sentence(_ text: String, score: Int) -> InputCandidate {
        InputCandidate(text: text, language: .simplifiedChinese, score: score).withChineseSentenceOrigin()
    }
}
