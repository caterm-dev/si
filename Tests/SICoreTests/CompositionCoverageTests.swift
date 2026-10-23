import Foundation
import Testing
@testable import SICore

struct CompositionCoverageTests {
    @Test func continuationBridgesPreserveScoresAndBytesAcrossGrouping() throws {
        let english = InputCandidate(text: "hello", language: .english, score: -5).withWordContext(.english)
        let chinese = InputCandidate(text: "中文", language: .simplifiedChinese, score: -6)
            .withWordContext(.chinese(["中文"], corpusScore: 0, usesContext: false))
        let ending = InputCandidate(text: "world", language: .english, score: -7).withWordContext(.english)
        let head = try #require(CandidateContinuation.joining(english, chinese))
        let tail = try #require(CandidateContinuation.joining(chinese, ending))
        let left = try #require(CandidateContinuation.joining(head, ending))
        let right = try #require(CandidateContinuation.joining(english, tail))
        #expect(abs(left.rankingScore - right.rankingScore) < 1e-12)
        #expect(left.text == "hello中文world" && left.isMixed)
        #expect(left.wordContext == right.wordContext)
        let decomposed = try #require(CandidateContinuation.joining(
            InputCandidate(text: "e", language: .simplifiedChinese, score: -1, isUserPhrase: true),
            InputCandidate(text: "\u{301}", language: .simplifiedChinese, score: -2)))
        #expect(Array(decomposed.text.utf8) == Array("e\u{301}".utf8))
        #expect(!decomposed.canLearn)
    }

    @Test func aCompatibleWholePathSuppliesItsActualContinuationScore() throws {
        let prefix = InputCandidate(text: "AB", language: .english, score: -1, consumedInputCount: 2)
        let trace = CandidateSourceTrace(sourceCount: 2, outputByteCount: 2, languages: 2, previous: nil)
        let whole = InputCandidate(text: "ABCD", language: .english, score: -20).withSourceTrace(trace)
        let provider = FixtureProvider(rows: ["abcd": [prefix, whole]])
        let result = CandidateEngine(providers: [provider]).candidates(for: "abcd", languages: [.english])
        #expect(result.first?.id == whole.id)
        let projected = try #require(result.first { $0.id == prefix.id })
        #expect(projected.rankingScore == -1)
        #expect(projected.inputScore == whole.rankingScore - CandidateScoring.partialConfirmationCost)
    }

    @Test func continuationAlignmentRequiresExactSourceAndOutputBytes() throws {
        for consumed in [1, 2] {
            let text = consumed == 1 ? "é" : "e\u{301}"
            let prefix = InputCandidate(text: text, language: .english, score: -1, consumedInputCount: consumed)
            let whole = InputCandidate(text: "éZ", language: .english, score: -20)
                .withSourceTrace(CandidateSourceTrace(sourceCount: 2, outputByteCount: 2, languages: 2, previous: nil))
            let tail = InputCandidate(text: "Tail", language: .english, score: -2)
            let provider = FixtureProvider(rows: ["abcd": [whole, prefix], "bcd": [tail], "cd": [tail]])
            let result = CandidateEngine(providers: [provider]).candidates(for: "abcd", languages: [.english])
            let projected = try #require(result.first { $0.id == prefix.id })
            #expect(projected.inputScore == -4)
            #expect(Array(projected.text.utf8) == Array(text.utf8))
        }
    }

    @Test func fullReadingsSupplyExactInteriorAlignmentThroughUmlautAliasesAndSeparators() throws {
        let decoder = PinyinDecoder(entries: [
            PinyinLexiconEntry(syllables: ["lv", "xiang", "hao"], text: "吕想好", upstreamWeight: 1_000_000),
            PinyinLexiconEntry(syllables: ["lv", "xiang"], text: "吕想", upstreamWeight: 100),
            PinyinLexiconEntry(syllables: ["hao"], text: "好", upstreamWeight: 100),
        ])
        let engine = CandidateEngine(providers: [DecoderProvider(decoder: decoder)])
        for input in ["lü'xiang'hao", "lu:'xiang'hao", "LÜ'Xiang'Hao"] {
            var session = InputSession(engine: engine)
            session.configure(languages: [.simplifiedChinese])
            session.append(input)
            let whole = try #require(session.candidates.first { $0.text == "吕想好" && !$0.isPartial })
            let prefix = try #require(session.candidates.first { $0.text == "吕想" && $0.isPartial })
            #expect(abs(prefix.inputScore - (whole.rankingScore - CandidateScoring.partialConfirmationCost)) < 1e-12)
            let count = try #require(prefix.consumedInputCount)
            let commit = session.commitResult(prefix, reason: .explicitSelection)
            #expect(commit.input == String(input.prefix(count)) && session.buffer.lowercased() == "hao")
            #expect(commit.text == "吕想" && commit.candidate?.appendsSpaceOnAcceptance == false)
        }
    }

    @Test func retainedWordPathsProvideLookaheadForOtherWordsAtTheSameBoundary() throws {
        let first = CandidateSourceTrace(sourceCount: 1, outputByteCount: 1, languages: 2, previous: nil,
            word: "C", wordLanguage: 2, lexicalCost: 2)
        let last = CandidateSourceTrace(sourceCount: 2, outputByteCount: 3, languages: 2, previous: first,
            word: "D", wordLanguage: 2, lexicalCost: 5)
        let transition = CandidateScoring.languageCost(previous: 2, next: 2)
        let whole = InputCandidate(text: "C D", language: .english, score: -8, rankingScore: -8 - transition)
            .withSourceTrace(last).withWordContext(.english)
        let prefix = InputCandidate(text: "X", language: .english, score: -4, consumedInputCount: 1)
            .withWordContext(.english)
        let engine = CandidateEngine(providers: [FixtureProvider(rows: ["cd": [whole, prefix]])])
        let result = engine.candidates(for: "cd", languages: [.english])
        let choice = try #require(result.first { $0.id == prefix.id })
        // X pays its own score, the D word cost, the language transition and one extra confirmation.
        #expect(abs(choice.inputScore - (-4 - 5 - transition - 1)) < 1e-12)
    }

    @Test(arguments: ["iwanttobuild", "nihaopengyou", "biruzhege", "danci", "xianshi",
                      "zhegeshurufakeyishuruzhongwenheyingwen"])
    func completeMatchesCompeteAgainstPrefixesWithTheirRemaindersAccountedFor(input: String) throws {
        let expected = ["iwanttobuild": "I want to build", "nihaopengyou": "你好朋友",
                        "biruzhege": "比如这个", "danci": "单词", "xianshi": "显示",
                        "zhegeshurufakeyishuruzhongwenheyingwen": "这个输入法可以输入中文和英文"][input]!
        for languages: Set<InputLanguage> in [[.english], [.simplifiedChinese], Set(InputLanguage.allCases)] {
            if input == "iwanttobuild" && !languages.contains(.english) { continue }
            if input != "iwanttobuild" && !languages.contains(.simplifiedChinese) { continue }
            var session = InputSession(candidateGeneration: .deferred)
            session.configure(languages: languages)
            session.append(input)
            let request = try #require(session.pendingCandidateRequest)
            for result in [request.generatePreview(), request.generate()] {
                let target = try #require(result.candidates.first { $0.text == expected && !$0.isPartial })
                #expect(result.candidates.prefix(5).contains { $0.id == target.id })
                if input != "xianshi" { #expect(result.candidates.first?.id == target.id) }
                #expect(target.remainingInputScore == 0)
                #expect(result.candidates.contains { $0.isPartial })
                #expect(result.candidates.last?.isLiteral == true && result.candidates.last?.text == input)
            }
        }
    }

    @Test func aPrefixPaysForTheActualRemainingSpellingAndCanStillBeatAWeakWholeChoice() throws {
        let whole = InputCandidate(text: "Complete", language: .english, score: -12)
        let short = InputCandidate(text: "A", language: .english, score: -2, consumedInputCount: 1)
        let long = InputCandidate(text: "ABC", language: .english, score: -4, consumedInputCount: 3)
        let provider = FixtureProvider(rows: [
            "abcdef": [whole, short, long],
            "bcdef": [InputCandidate(text: "BCDEF", language: .english, score: -20)],
            "def": [InputCandidate(text: "DEF", language: .english, score: -5)],
        ])
        let result = CandidateEngine(providers: [provider]).candidates(for: "abcdef", languages: [.english])
        #expect(result.map(\.text) == ["ABC", "Complete", "A", "abcdef"])
        let first = try #require(result.first)
        #expect(first.rankingScore == -4 && first.score == -4)
        #expect(first.remainingInputScore == -6 && first.inputScore == -10)
        #expect(first.id == long.id)
        #expect(result.first { $0.id == short.id }?.inputScore == -23)
    }

    @Test func unknownOrPartialOnlyTailsCannotBeSkippedForFree() throws {
        for suffixRows: [InputCandidate] in [[], [InputCandidate(text: "D", language: .english, score: 1_000, consumedInputCount: 1)]] {
            let prefix = InputCandidate(text: "ABC", language: .english, score: -4, consumedInputCount: 3)
            let provider = FixtureProvider(rows: ["abcdef": [prefix], "def": suffixRows])
            let result = CandidateEngine(providers: [provider]).candidates(for: "abcdef", languages: [.english])
            let choice = try #require(result.first { $0.id == prefix.id })
            #expect(choice.inputScore.isFinite && choice.inputScore < choice.rankingScore)
            #expect(choice.remainingInputScore < -Double("def".utf8.count * 8))
            #expect(result.last?.text == "abcdef" && result.last?.isLiteral == true)
        }
    }

    @Test func remainderPreferencesCannotTrainOrInflateTheConfirmedPrefix() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let prefix = InputCandidate(text: "ABC", language: .english, score: -4, consumedInputCount: 3)
        let provider = FixtureProvider(rows: ["abcdef": [prefix], "def": [InputCandidate(text: "DEF", language: .english, score: -5)]])
        let engine = CandidateEngine(providers: [provider])
        let learnedTail = LearningProfile(entries: [
            LearnedPreference(input: "def", text: "DEF", language: .english, strength: 8, lastUsed: now),
        ], now: now)
        let base = engine.candidates(for: "abcdef", languages: [.english], now: now)
        let learned = engine.candidates(for: "abcdef", languages: [.english], learning: learnedTail, now: now)
        #expect(base == learned)
        var session = InputSession(engine: engine)
        session.configure(languages: [.english])
        session.append("abcdef")
        let choice = try #require(session.candidates.first { $0.id == prefix.id })
        let commit = session.commitResult(choice, reason: .explicitSelection, now: now)
        #expect(commit.input == "abc" && commit.text == "ABC" && session.buffer == "def")
        var profile = LearningProfile()
        let recorded = profile.record(commit, now: now)
        #expect(recorded)
        #expect(profile.entries.count == 1 && profile.entries.first?.input == "abc")
        #expect(commit.candidate?.rankingScore == -4)
    }
}

private struct FixtureProvider: CandidateProvider {
    let language = InputLanguage.english
    let rows: [String: [InputCandidate]]
    func candidates(for input: String) -> [InputCandidate] { rows[input] ?? [] }
}

private struct DecoderProvider: CandidateProvider {
    let language = InputLanguage.simplifiedChinese
    let decoder: PinyinDecoder
    func candidates(for input: String) -> [InputCandidate] {
        decoder.compositionCandidates(for: input, languages: [.simplifiedChinese])
    }
}
