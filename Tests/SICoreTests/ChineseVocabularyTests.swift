import Foundation
import Testing
@testable import SICore

struct ChineseVocabularyTests {
    @Test func sentenceFinalMaKeepsChineseAndEnglishAlternatives() throws {
        let engine = CandidateEngine()
        let input = "nengxiangbanfayouhuama"
        for languages: Set<InputLanguage> in [[.simplifiedChinese], Set(InputLanguage.allCases)] {
            let values = engine.candidates(for: input, languages: languages)
            let first = try #require(values.first)
            #expect(first.text == "能想办法优化吗")
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

    @Test func everyOriginalEntryKeepsItsDeclaredReadingAndScore() {
        let merged = Dictionary(grouping: ChineseLexiconData.entries, by: { $0.code })
        for original in OriginalPinyinLexicon.entries {
            #expect(merged[original.code, default: []].contains {
                $0.text == original.text && $0.syllables == original.syllables && $0.score == original.score
            })
        }
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
        #expect(greeting.hasCompletion && greeting.rankingScore > 84)
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
        var combinations: [(text: String, cost: Double)] = []
        for first in entries {
            for second in entries {
                let cost = 16.0 + Double(200 - first.score - second.score) / 4
                combinations.append((first.text + second.text, cost))
            }
        }
        let exhaustive = combinations.sorted {
            $0.cost == $1.cost ? $0.text < $1.text : $0.cost < $1.cost
        }.prefix(12)
        for order in [entries, Array(entries.reversed())] {
            let result = PinyinDecoder(entries: order).candidates(for: "aa")
            #expect(result.map(\.text) == exhaustive.map(\.text))
            #expect(result.map(\.rankingScore) == exhaustive.map { 94 - $0.cost / 10 })
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
