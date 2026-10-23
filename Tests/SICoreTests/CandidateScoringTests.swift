import Foundation
import Testing
@testable import SICore

struct CandidateScoringTests {
    private let languages = Set(InputLanguage.allCases)

    @Test func lingHomophonesOutrankTheMixedSplitInPreviewAndFullSearch() throws {
        let engine = CandidateEngine()
        let profile = LearningProfile()
        for values in [engine.candidates(for: "ling", languages: languages),
                       engine.previewCandidates(for: "ling", languages: languages, learning: profile,
                                                dictionary: UserDictionary(), now: .now, context: nil)] {
            let zero = try #require(values.firstIndex { $0.text == "零" && !$0.isPartial })
            let split = try #require(values.firstIndex { $0.text == "里NG" && $0.isMixed && !$0.isPartial })
            #expect(zero < split)
            #expect(values[zero].rankingScore > values[split].rankingScore)
            #expect(zero < 27)
            #expect(values.contains { $0.text == "lingo" && $0.language == .english })
            #expect(values.last?.text == "ling" && values.last?.isLiteral == true)
        }
    }

    @Test(arguments: ["ling", "shi", "he", "nihao", "nihaoworld", "iwanttobuild", "woxiangyaodeploy"])
    func completeCandidatesCompeteByScoreWithoutReservedFrontPositions(input: String) {
        let engine = CandidateEngine()
        let values = engine.candidates(for: input, languages: languages)
        let complete = values.filter { !$0.isPartial && !$0.isLiteral }
        for (previous, next) in zip(complete, complete.dropFirst()) {
            #expect(previous.rankingScore >= next.rankingScore)
        }
        #expect(Set(values.map(\.id)).count == values.count)
        #expect(values == engine.candidates(for: input, languages: languages))
    }

    @Test func aChineseWordHasTheSameCostBeforeAnEnglishWordAsItDoesAlone() throws {
        let decoder = PinyinDecoder(entries: [PinyinLexiconEntry(syllables: ["ling"], text: "零", upstreamWeight: 25_133)])
        let alone = try #require(decoder.candidates(for: "ling").first { $0.text == "零" })
        let values = decoder.compositionCandidates(for: "lingworld", languages: languages)
        let prefix = try #require(values.first { $0.text == "零" && $0.consumedInputCount == 4 })
        let joined = try #require(values.first { $0.text == "零world" && !$0.isPartial })
        let word = try #require(EnglishLexicon.matches(for: "world").first { $0.text == "world" })
        #expect(abs(alone.rankingScore - prefix.rankingScore) < 1e-12)
        // The joined path pays for world and a language transition, with no second BOS prior.
        let expected = alone.rankingScore - word.cost(typedLength: 5) + 1 + log2(RankingCalibration.switchProbability)
        #expect(abs(joined.rankingScore - expected) < 1e-12)
    }

    @Test func englishWordsUseTheSameCostInEnglishAndMixedSentences() throws {
        let decoder = PinyinDecoder(entries: [PinyinLexiconEntry(syllables: ["ling"], text: "零", upstreamWeight: 25_133)])
        let mixed = try #require(decoder.compositionCandidates(for: "lingworld", languages: languages)
            .first { $0.text == "零world" && !$0.isPartial })
        let chinese = try #require(decoder.candidates(for: "ling").first { $0.text == "零" })
        let english = try #require(CandidateEngine().candidates(for: "deployworld", languages: [.english])
            .first { $0.text == "deploy world" && !$0.isPartial })
        let deploy = try #require(EnglishCandidateProvider().candidates(for: "deploy").first { $0.text == "deploy" })
        let mixedWorld = mixed.rankingScore - chinese.rankingScore - log2(RankingCalibration.switchProbability)
        let englishWorld = english.rankingScore - deploy.rankingScore - log2(1 - RankingCalibration.switchProbability)
        #expect(abs(mixedWorld - englishWorld) < 1e-12)
    }

    @Test func packagedChineseContextHasTheSameScoreInBothDecoders() throws {
        let alone = try #require(PinyinDecoder.standard.candidates(for: "nihao").first { $0.text == "你好" })
        let prefixes = LexicalCompositionDecoder.mixed.compositionCandidates(for: "nihaoworld", languages: languages)
        let prefix = try #require(prefixes.first { $0.text == "你好" && $0.consumedInputCount == 5 })
        #expect(abs(prefix.rankingScore - alone.rankingScore) < 1e-12)
    }

    @Test func partialSpellingPaysForMissingSyllableLetters() throws {
        let decoder = PinyinDecoder(entries: [PinyinLexiconEntry(syllables: ["ni", "hao"], text: "你好", upstreamWeight: 100_000)])
        let complete = try #require(decoder.candidates(for: "nihao").first { $0.text == "你好" })
        let incomplete = try #require(decoder.candidates(for: "niha").first { $0.text == "你好" })
        #expect(abs(complete.rankingScore - incomplete.rankingScore - 1) < 1e-12)
        #expect(incomplete.hasCompletion)
    }

    @Test func disabledLanguagesAndPersonalPinsKeepTheirContracts() throws {
        let engine = CandidateEngine()
        for enabled: Set<InputLanguage> in [[], [.english], [.simplifiedChinese]] {
            let values = engine.candidates(for: "ling", languages: enabled)
            #expect(!values.contains { $0.isMixed })
            #expect(values.allSatisfy { $0.language.map(enabled.contains) ?? true })
            #expect(values.last?.text == "ling" && values.last?.isLiteral == true)
        }
        let dictionary = try UserDictionary(entries: [UserPhrase(input: "ling", text: "自选", language: .simplifiedChinese, isPinned: true)])
        let pinned = engine.candidates(for: "ling", languages: languages, dictionary: dictionary)
        #expect(pinned.first?.text == "自选" && pinned.first?.isPreferred == true)
        #expect(pinned.first?.canLearn == false)
        #expect(pinned.contains { $0.text == "零" })
    }

    @Test func personalCodeCostsIgnoreSeparatorsAndUnrelatedDictionaryEntries() throws {
        let phrase = try UserPhrase(input: "xi'an", text: "测试", language: .simplifiedChinese)
        var dictionary = try UserDictionary(entries: [phrase])
        let direct = try #require(dictionary.candidates(for: "xi'an", languages: languages).first)
        try dictionary.upsert(UserPhrase(input: "abc", text: "Synthetic expansion", language: .english))
        let afterAddition = try #require(dictionary.candidates(for: "xi'an", languages: languages).first)
        #expect(afterAddition.rankingScore == direct.rankingScore)
        let prefixes = LexicalCompositionDecoder.mixed.compositionCandidates(for: "xi'andeploy", languages: languages,
                                                                           dictionary: dictionary)
        let prefix = try #require(prefixes.first { $0.text == "测试" && $0.isUserPhrase && $0.consumedInputCount == 5 })
        #expect(abs(prefix.rankingScore - direct.rankingScore) < 1e-12)
        #expect(!prefix.canLearn)
    }
}
