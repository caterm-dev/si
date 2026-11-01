import Foundation
import Testing
@testable import SICore

struct CompositionCoverageTests {
    @Test(arguments: [-1_000.0, -2.0, 100.0])
    func prefixScoreIgnoresMatchingWholePathsAndSuffixConversions(wholeScore: Double) throws {
        let prefix = InputCandidate(text: "A", language: .english, score: -2, consumedInputCount: 1)
        let other = InputCandidate(text: "B", language: .english, score: -4, consumedInputCount: 1)
        let whole = InputCandidate(text: "A Z", language: .english, score: Int(wholeScore), rankingScore: wholeScore)
            .withSourceTrace(CandidateSourceTrace(sourceCount: 1, outputByteCount: 1, languages: 2, previous: nil))
        let rows = [prefix, other, whole]
        for ordered in [rows, Array(rows.reversed())] {
            let engine = CandidateEngine(providers: [NoSuffixProvider(input: "abcd", values: ordered)])
            let values = engine.candidates(for: "abcd", languages: [.english])
            let choice = try #require(values.first { $0.id == prefix.id })
            let alternative = try #require(values.first { $0.id == other.id })
            var session = InputSession(engine: engine, candidateGeneration: .deferred)
            session.append("abcd")
            #expect(session.presentationScore(for: choice) == 3)
            #expect(session.presentationScore(for: alternative) == 1)
            #expect(choice.inputScore == -2 && alternative.inputScore == -4)
            #expect(choice.score == -2 && choice.rankingScore == -2)
            #expect(values.last?.text == "abcd" && values.last?.isLiteral == true)
        }
    }

    @Test(arguments: ["def", "unknownXYZ", String(repeating: "q", count: 40)])
    func unknownRemaindersDoNotPenalizeOrTriggerAdditionalProviderQueries(suffix: String) throws {
        let prefix = InputCandidate(text: "ABC", language: .english, score: -4, consumedInputCount: 3)
        let input = "abc" + suffix
        let engine = CandidateEngine(providers: [NoSuffixProvider(input: input, values: [prefix])])
        let values = engine.candidates(for: input, languages: [.english])
        let choice = try #require(values.first { $0.id == prefix.id })
        var session = InputSession(engine: engine, candidateGeneration: .deferred)
        session.append(input)
        #expect(session.presentationScore(for: choice) == 11)
        #expect(choice.inputScore == -4)
        #expect(values.last?.text == input && values.last?.isLiteral == true)
    }

    @Test func prefixScoreDoesNotDependOnCanonicalOutputOrSourceAlignmentInOtherCandidates() throws {
        for consumed in [1, 2] {
            let text = consumed == 1 ? "é" : "e\u{301}"
            let prefix = InputCandidate(text: text, language: .english, score: -1, consumedInputCount: consumed)
            let whole = InputCandidate(text: "éZ", language: .english, score: -20)
                .withSourceTrace(CandidateSourceTrace(sourceCount: 2, outputByteCount: 2, languages: 2, previous: nil))
            let engine = CandidateEngine(providers: [NoSuffixProvider(input: "abcd", values: [whole, prefix])])
            let values = engine.candidates(for: "abcd", languages: [.english])
            let choice = try #require(values.first { $0.id == prefix.id })
            #expect(choice.inputScore == -1)
            #expect(Array(choice.text.utf8) == Array(text.utf8))
        }
    }

    @Test func prefixScoresAndCommitsUseExactUmlautAliasesAndSeparators() throws {
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
            #expect(session.candidates.contains { $0.text == "吕想好" && !$0.isPartial })
            let prefix = try #require(session.candidates.first { $0.text == "吕想" && $0.isPartial })
            let count = try #require(prefix.consumedInputCount)
            let standalone = try #require(decoder.candidates(for: String(input.prefix(count))).first { $0.text == "吕想" })
            #expect(prefix.inputScore == standalone.rankingScore)
            let commit = session.commitResult(prefix, reason: .explicitSelection)
            #expect(commit.input == String(input.prefix(count)) && session.buffer.lowercased() == "hao")
            #expect(commit.text == "吕想" && commit.candidate?.appendsSpaceOnAcceptance == false)
        }
    }

    @Test(arguments: ["iwanttobuild", "nihaopengyou", "biruzhege", "danci", "xianshi",
                      "zhegeshurufakeyishuruzhongwenheyingwen"])
    func completeCandidatesRemainAvailableWithoutAPreferenceOverPrefixes(input: String) throws {
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
                #expect(result.candidates.contains { $0.text == expected && !$0.isPartial })
                #expect(result.candidates.allSatisfy { $0.inputScore == $0.rankingScore })
                #expect(result.candidates.contains { $0.isPartial })
                #expect(result.candidates.last?.isLiteral == true && result.candidates.last?.text == input)
            }
        }
    }

    @Test func coverageRewardCanOvercomeALexicalGapWithoutMakingLengthAbsolute() throws {
        let whole = InputCandidate(text: "Complete", language: .english, score: -20)
        let short = InputCandidate(text: "A", language: .english, score: -2, consumedInputCount: 1, rankingScore: -2.25)
        let long = InputCandidate(text: "ABC", language: .english, score: -4, consumedInputCount: 3, rankingScore: -4.5)
        let provider = NoSuffixProvider(input: "abcdef", values: [whole, short, long])
        let result = CandidateEngine(providers: [provider]).candidates(for: "abcdef", languages: [.english])
        #expect(result.map(\.text) == ["ABC", "Complete", "A", "abcdef"])
        #expect(result.first { $0.id == short.id }?.inputScore == -2.25)
        #expect(result.first { $0.id == long.id }?.inputScore == -4.5)
    }

    @Test func remainderPreferencesCannotTrainOrInflateTheConfirmedPrefix() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let prefix = InputCandidate(text: "ABC", language: .english, score: -4, consumedInputCount: 3)
        let provider = FixtureProvider(rows: ["abcdef": [prefix], "def": [InputCandidate(text: "DEF", language: .english, score: -5)]])
        let engine = CandidateEngine(providers: [provider])
        let learnedTail = LearningProfile(entries: [
            LearnedPreference(input: "def", text: "DEF", language: .english, strength: 8, lastUsed: now),
        ], now: now)
        #expect(engine.candidates(for: "abcdef", languages: [.english], now: now)
            == engine.candidates(for: "abcdef", languages: [.english], learning: learnedTail, now: now))
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

private struct NoSuffixProvider: CandidateProvider {
    let language = InputLanguage.english
    let input: String
    let values: [InputCandidate]
    func candidates(for input: String) -> [InputCandidate] {
        #expect(input == self.input)
        return input == self.input ? values : []
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
