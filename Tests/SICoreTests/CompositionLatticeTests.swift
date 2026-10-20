import Testing
@testable import SICore

struct CompositionLatticeTests {
    private let languages = Set(InputLanguage.allCases)

    @Test func longPersonalExpansionsAreBoundedWithoutDroppingDirectMatchesOrLiteralInput() throws {
        let entries = try (0..<20).map {
            try UserPhrase(input: "a", text: String(repeating: "x", count: 1_000) + "\($0)", language: .english)
        }
        let dictionary = try UserDictionary(entries: entries)
        let direct = CandidateEngine().candidates(for: "a", languages: languages, dictionary: dictionary)
        #expect(direct.count(where: { $0.isUserPhrase && !$0.isPartial }) == 20)
        let input = String(repeating: "a", count: 20)
        let composed = CandidateEngine().candidates(for: input, languages: languages, dictionary: dictionary)
        #expect(composed.allSatisfy { $0.text.utf8.count <= PinyinDecoder.maximumOutputBytes })
        #expect(composed.last?.text == input)
        #expect(composed.contains { $0.isPartial && $0.isUserPhrase })
    }

    @Test func constructedRankingPreservesLexicalPreferencesInsteadOfIntegerTies() {
        let tiny = PinyinDecoder(entries: [
            PinyinLexiconEntry(syllables: ["wo"], text: "我", score: 100),
            PinyinLexiconEntry(syllables: ["wo"], text: "握", score: 99),
            PinyinLexiconEntry(syllables: ["shi"], text: "是", score: 100),
            PinyinLexiconEntry(syllables: ["shi"], text: "时", score: 99),
        ])
        #expect(tiny.candidates(for: "woshi").first?.text == "我是")
        let engine = CandidateEngine()
        for (input, expected) in [("woshi", "我是"), ("nishi", "你是"), ("woyao", "我要"),
                                  ("zhongguoren", "中国人"), ("womenhao", "我们好")] {
            #expect(engine.candidates(for: input, languages: [.simplifiedChinese]).first?.text == expected)
        }
    }

    @Test func coherentChinesePathsOutrankAccidentalEnglishWordsWithoutHidingThem() {
        let candidates = CandidateEngine().candidates(for: "womenqubeijing", languages: languages)
        #expect(candidates.first?.text == "我们去北京")
        #expect(candidates.contains { $0.text == "women去北京" && $0.isMixed })
        #expect(candidates.last?.isLiteral == true)
    }

    @Test func longCompositionsDoNotLoseCoherenceThroughAFixedScoreFloor() {
        let candidates = CandidateEngine().candidates(for: String(repeating: "a", count: 64), languages: languages)
        #expect(candidates.first?.text == String(repeating: "啊", count: 64))
        #expect(candidates.contains { $0.isMixed })
    }

    @Test func personalChineseAndEnglishNodesParticipateInLongerCompositions() throws {
        let dictionary = try UserDictionary(entries: [
            UserPhrase(input: "xm", text: "小明", language: .simplifiedChinese),
            UserPhrase(input: "gh", text: "GitHub", language: .english),
            UserPhrase(input: "pg", text: "iPhone", language: .simplifiedChinese),
        ])
        let engine = CandidateEngine()
        let chinese = try #require(engine.candidates(for: "woaixm", languages: languages, dictionary: dictionary)
            .first { $0.text == "我爱小明" && !$0.isPartial })
        #expect(chinese.isUserPhrase)
        #expect(!chinese.canLearn)
        let mixed = try #require(engine.candidates(for: "nihaogh", languages: languages, dictionary: dictionary)
            .first { $0.text == "你好GitHub" && !$0.isPartial })
        #expect(mixed.isUserPhrase && mixed.isMixed)
        #expect(CandidateContext(candidate: mixed) == nil)
        #expect(engine.candidates(for: "woaipg", languages: [.simplifiedChinese], dictionary: dictionary)
            .contains { $0.text == "我爱iPhone" && !$0.isMixed && $0.isUserPhrase })
        #expect(!engine.candidates(for: "nihaogh", languages: [.simplifiedChinese], dictionary: dictionary)
            .contains { $0.text.contains("GitHub") })
    }

    @Test func indexEditsAndDeletionDoNotLeavePrivateLatticeNodesBehind() throws {
        let phrase = try UserPhrase(input: "xm", text: "小明", language: .simplifiedChinese)
        var dictionary = try UserDictionary(entries: [phrase])
        let engine = CandidateEngine()
        #expect(engine.candidates(for: "woaixm", languages: languages, dictionary: dictionary).contains { $0.isUserPhrase })
        try dictionary.upsert(UserPhrase(id: phrase.id, input: "zs", text: "张三", language: .simplifiedChinese))
        #expect(!engine.candidates(for: "woaixm", languages: languages, dictionary: dictionary).contains { $0.isUserPhrase })
        #expect(engine.candidates(for: "woaizs", languages: languages, dictionary: dictionary).contains { $0.text == "我爱张三" })
        dictionary.remove(id: phrase.id)
        #expect(!engine.candidates(for: "woaizs", languages: languages, dictionary: dictionary).contains { $0.isUserPhrase })
    }

    @Test func explicitBoundariesConstrainPersonalNodesAndTrailingCompletions() throws {
        let dictionary = try UserDictionary(entries: [UserPhrase(input: "xi'an", text: "测试城市", language: .simplifiedChinese)])
        let engine = CandidateEngine()
        #expect(engine.candidates(for: "woxihuanxi'an", languages: languages, dictionary: dictionary)
            .contains { $0.text == "我喜欢测试城市" })
        #expect(!engine.candidates(for: "woxihuanxia'n", languages: languages, dictionary: dictionary)
            .contains { $0.text == "我喜欢测试城市" })
        let trailing = PinyinDecoder.standard.candidates(for: "xian'")
        #expect(!trailing.contains { $0.text == "项目" })
        #expect(trailing.contains { $0.text == "现在" })
    }

    @Test func fullAndInitialSyllablesCanBeCombined() {
        for input in ["nhao", "nih", "ni'h", "n'hao"] {
            #expect(PinyinDecoder.standard.candidates(for: input).contains { $0.text == "你好" })
        }
        #expect(PinyinDecoder.standard.candidates(for: "n'h").contains { $0.text == "你好" })
    }

    @Test func incompleteMixedWordAndUnknownSpansHaveDistinctPrivacyBehavior() throws {
        let engine = CandidateEngine()
        let completion = try #require(engine.candidates(for: "nihaowor", languages: languages)
            .first { $0.text == "你好world" && !$0.isPartial })
        #expect(!completion.hasLiteralSegments)
        // Additional known segmentations can suppress verbatim paths; exact input still survives.
        #expect(engine.candidates(for: "nihaowor", languages: languages).last?.text == "nihaowor")
        #expect(engine.candidates(for: "nihaowor", languages: languages).last?.isLiteral == true)
        // QWERT is now a lexical technology entry. Keep the unknown-span fixture
        // independent of it, and also cover an unknown tail after a known product.
        #expect(EnglishLexicon.matches(for: "qz").isEmpty)
        for (input, output) in [("nihaoQzXvJk", "你好QzXvJk"), ("QzXvJknihao", "QzXvJk你好"),
                                ("nihaogmailQzXvJk", "你好GmailQzXvJk")] {
            let candidates = engine.candidates(for: input, languages: languages)
            let preserved = try #require(candidates.first { $0.text == output && !$0.isPartial })
            #expect(preserved.hasLiteralSegments)
            #expect(!preserved.canLearn)
            #expect(CandidateContext(candidate: preserved) == nil)
            var profile = LearningProfile()
            let learned = profile.record(InputCommit(input: input, candidate: preserved, reason: .explicitSelection))
            #expect(!learned)
            #expect(candidates.last?.text == input && candidates.last?.isLiteral == true)
        }
    }
}
