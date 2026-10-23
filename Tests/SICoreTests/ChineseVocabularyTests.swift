import Foundation
import Testing
@testable import SICore

struct ChineseVocabularyTests {
    @Test func wholeSpellingUsesHomophoneFrequenciesWithoutOverridingExplicitLearning() throws {
        let decoder = PinyinDecoder(entries: [
            PinyinLexiconEntry(syllables: ["de"], text: "的", upstreamWeight: 1 << 40),
            PinyinLexiconEntry(syllables: ["dan", "ci"], text: "单词", upstreamWeight: 225_415),
            PinyinLexiconEntry(syllables: ["dan", "ci"], text: "单次", upstreamWeight: 25_195),
            PinyinLexiconEntry(syllables: ["dan"], text: "但", upstreamWeight: 800_000),
            PinyinLexiconEntry(syllables: ["ci"], text: "此", upstreamWeight: 900_000),
            PinyinLexiconEntry(syllables: ["xian"], text: "先", upstreamWeight: 2_000_000),
            PinyinLexiconEntry(syllables: ["xi", "an"], text: "西安", upstreamWeight: 500_000),
        ])
        for preview in [false, true] {
            let values = decoder.compositionCandidates(for: "danci", languages: [.simplifiedChinese], preview: preview)
            let word = try #require(values.first { $0.text == "单词" })
            let once = try #require(values.first { $0.text == "单次" })
            #expect(values.first?.text == "单词")
            #expect(abs(word.rankingScore - once.rankingScore - log2(225_415.0 / 25_195.0)) < 1e-12)
            let ambiguous = decoder.compositionCandidates(for: "xian", languages: [.simplifiedChinese], preview: preview)
            // The two complete readings compete by frequency, spelling and character cost.
            #expect(ambiguous.first?.text == "西安")
            #expect(ambiguous.contains { $0.text == "先" })
            #expect(decoder.compositionCandidates(for: "xi'an", languages: [.simplifiedChinese], preview: preview).first?.text == "西安")
        }
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let profile = LearningProfile(entries: [
            LearnedPreference(input: "danci", text: "但此", language: .simplifiedChinese, strength: 8, lastUsed: now),
        ], now: now)
        let personalized = decoder.compositionCandidates(for: "danci", languages: [.simplifiedChinese], learning: profile, now: now)
        #expect(personalized.first?.text == "但此")
        #expect(personalized.contains { $0.text == "单词" })
    }

    @Test func sentenceFinalMaKeepsChineseAndEnglishAlternatives() throws {
        let engine = CandidateEngine()
        let input = "nengxiangbanfayouhuama"
        for languages: Set<InputLanguage> in [[.simplifiedChinese], Set(InputLanguage.allCases)] {
            let values = engine.candidates(for: input, languages: languages)
            let first = try #require(values.first)
            #expect(first.text.hasSuffix("吗"))
            #expect(values.prefix(3).contains { $0.text == "能想办法优化吗" })
            #expect(!first.isPartial && !first.isMixed && !first.hasCompletion && !first.hasLiteralSegments)
            #expect(values.last?.text == input && values.last?.isLiteral == true)
            #expect(values == engine.candidates(for: input, languages: languages))
            if languages.contains(.english) {
                #expect(values.contains { $0.text == "能想办法优化ma" && $0.isMixed && !$0.isPartial })
            }
        }

        // A saved English token choice may reorder results, but must keep the Chinese ending available.
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let profile = LearningProfile(entries: [
            LearnedPreference(input: "ma", text: "ma", language: .english, strength: 8, lastUsed: now),
        ], now: now)
        let personalized = engine.candidates(for: input, languages: Set(InputLanguage.allCases),
                                             learning: profile, now: now)
        #expect(personalized.contains { $0.text == "能想办法优化吗" && !$0.isPartial })
        #expect(personalized.contains { $0.text == "能想办法优化ma" && $0.isMixed && !$0.isPartial })
        #expect(personalized.last?.text == input && personalized.last?.isLiteral == true)
    }

    @Test func importedWordsCharactersAndReadingsJoinTheExistingEngine() {
        let engine = CandidateEngine()
        for (input, expected) in [("zimu", "字幕"), ("shujuku", "数据库"), ("zhuban", "主板"),
                                  ("rengongzhineng", "人工智能"), ("cikuweihu", "词库维护")] {
            let values = engine.candidates(for: input, languages: [.simplifiedChinese])
            #expect(values.contains { $0.text == expected && !$0.isPartial })
            #expect(values.last?.text == input && values.last?.isLiteral == true)
            #expect(values == engine.candidates(for: input, languages: [.simplifiedChinese]))
            #expect(!engine.candidates(for: input, languages: [.english]).contains { $0.text == expected })
        }
        #expect(engine.candidates(for: "zimusubtitle", languages: Set(InputLanguage.allCases))
            .contains { $0.text == "字幕subtitle" && $0.isMixed && !$0.hasLiteralSegments })
        #expect(engine.candidates(for: "xing", languages: [.simplifiedChinese]).contains { $0.text == "行" })
        #expect(engine.candidates(for: "hang", languages: [.simplifiedChinese]).contains { $0.text == "行" })
    }

    @Test func upstreamHomophoneWeightsKeepTheirRatioAndReachConstructedSentences() throws {
        let engine = CandidateEngine()
        let values = engine.candidates(for: "guo", languages: [.simplifiedChinese])
        let past = try #require(values.first { $0.text == "过" })
        let country = try #require(values.first { $0.text == "国" })
        let pastEntry = try #require(ChineseLexicon.standard.exactMatches(["guo"]).first { $0.text == "过" })
        let countryEntry = try #require(ChineseLexicon.standard.exactMatches(["guo"]).first { $0.text == "国" })
        #expect(pastEntry.weight == 3_229_619 && countryEntry.weight == 188_165)
        #expect(abs(past.rankingScore - country.rankingScore - log2(Double(pastEntry.weight) / Double(countryEntry.weight))) < 1e-12)
        #expect(values.first?.text == "过")
        for preview in [false, true] {
            let sentence = PinyinDecoder.standard.compositionCandidates(for: "tianjiaguonameduo",
                languages: Set(InputLanguage.allCases), preview: preview)
            #expect(sentence.first?.text == "添加过那么多")
            if let country = sentence.firstIndex(where: { $0.text == "添加国那么多" }) {
                #expect(country > 0)
            }
        }
    }

    @Test func fractionalUpstreamWeightsAndUnweightedCoverageDoNotLosePrecision() throws {
        let decoder = PinyinDecoder(entries: [
            PinyinLexiconEntry(syllables: ["guo"], text: "国", upstreamWeight: 3_063_867),
            PinyinLexiconEntry(syllables: ["guo"], text: "过", upstreamWeight: 7_307_184),
            PinyinLexiconEntry(syllables: ["guo"], text: "果", upstreamWeight: nil),
        ])
        let values = decoder.candidates(for: "guo")
        let country = try #require(values.first { $0.text == "国" })
        let expected = (log(3_063_867.0) - 22) / log(2.0) - 1 + log2(128.0 / 135)
        #expect(abs(country.rankingScore - expected) < 1e-12)
        #expect(values.first?.text == "过")
        #expect(values.contains { $0.text == "果" && $0.rankingScore < country.rankingScore })
        let unweighted = PinyinDecoder(entries: [
            PinyinLexiconEntry(syllables: ["ci"], text: "词", upstreamWeight: nil),
            PinyinLexiconEntry(syllables: ["ci"], text: "辞", upstreamWeight: nil),
        ]).candidates(for: "ci")
        #expect(unweighted.count == 2 && unweighted[0].rankingScore == unweighted[1].rankingScore)
    }

    @Test func manyExactAlternativesDoNotEraseStrongerCompletionDerivations() throws {
        let alternatives = (0..<24).map {
            PinyinLexiconEntry(syllables: ["ha"], text: String(UnicodeScalar(0x4E00 + $0)!), score: 100)
        }
        let decoder = PinyinDecoder(entries: alternatives + [
            PinyinLexiconEntry(syllables: ["ni"], text: "你"),
            PinyinLexiconEntry(syllables: ["hao"], text: "好"),
            PinyinLexiconEntry(syllables: ["ni", "hao"], text: "你好"),
        ])
        let values = decoder.candidates(for: "niha")
        let greeting = try #require(values.first { $0.text == "你好" })
        #expect(greeting.hasCompletion && greeting.rankingScore.isFinite)
        #expect(values.contains { !$0.hasCompletion })
        #expect(values.filter { $0.hasCompletion }.count <= 12)
        #expect(values.filter { !$0.hasCompletion }.count <= 12)
    }

    @Test func learnedSingleCharactersCannotPromoteAChineseAbbreviationInsideAnEnglishWord() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let profile = LearningProfile(entries: [
            LearnedPreference(input: "le", text: "了", language: .simplifiedChinese, strength: 8, lastUsed: now),
        ], now: now)
        let values = CandidateEngine().candidates(for: "nihaotitle", languages: Set(InputLanguage.allCases),
                                                 learning: profile, now: now)
        let abbreviation = try #require(values.first { $0.text == "你好体坛了" && !$0.isPartial })
        #expect(abbreviation.tokenLearningBonus == 0)
        #expect(values.first?.text == "你好title")
    }

    @Test func largeTerminalBatchesMatchAnIndependentExhaustiveRanking() {
        let entries = (0..<128).map {
            PinyinLexiconEntry(syllables: ["a"], text: String(UnicodeScalar(0x4E00 + $0)!), score: 100 - $0 % 16)
        }
        let total = entries.reduce(1.0) { $0 + exp2(Double($1.score) / 10) }
        var combinations: [(text: String, cost: Double)] = []
        for first in entries {
            for second in entries {
                let cost = 2 * log2(total) - Double(first.score + second.score) / 10 + 1 - log2(1 - RankingCalibration.switchProbability) + 2 * log2(1.5)
                combinations.append((first.text + second.text, cost))
            }
        }
        let exhaustive = combinations.sorted {
            $0.cost == $1.cost ? $0.text < $1.text : $0.cost < $1.cost
        }.prefix(12)
        for order in [entries, Array(entries.reversed())] {
            let result = PinyinDecoder(entries: order).candidates(for: "aa")
            #expect(result.map(\.text) == exhaustive.map(\.text))
            for (candidate, path) in zip(result, exhaustive) { #expect(abs(candidate.rankingScore + path.cost) < 1e-10) }
        }
    }

    @Test func sharedReadingsKeepEveryDirectAlternativeAndMixedInitialBoundary() {
        let entries = (0..<40).map {
            PinyinLexiconEntry(syllables: ["xi", "an"], text: "测试" + String(UnicodeScalar(0x4E00 + $0)!), score: 100 - $0)
        }
        let decoder = PinyinDecoder(entries: entries + [PinyinLexiconEntry(syllables: ["xian"], text: "先")])
        for spelling in ["xi'an", "x'an", "x'a"] {
            let values = decoder.candidates(for: spelling)
            #expect(entries.allSatisfy { entry in values.contains { $0.text == entry.text } })
            #expect(!values.contains { $0.text == "先" })
        }
    }
}
