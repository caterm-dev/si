import Foundation
import Testing
@testable import SICore

struct ChineseFrequencyRankingTests {
    @Test func frequentNaturalWordsBeatCrossBoundaryFragmentsInBothSearchStages() throws {
        for input in ["nawomenzaichaxun", "na'wo'men'zai'cha'xun"] {
            for languages: Set<InputLanguage> in [[.simplifiedChinese], Set(InputLanguage.allCases)] {
                var session = InputSession(candidateGeneration: .deferred)
                session.configure(languages: languages)
                session.append(input)
                let request = try #require(session.pendingCandidateRequest)
                for values in [request.generatePreview().candidates, request.generate().candidates] {
                    let first = try #require(values.first)
                    #expect(first.text == "那我们在查询")
                    #expect(!first.isPartial && !first.isMixed && !first.isUserPhrase)
                    #expect(values.last?.text == input && values.last?.isLiteral == true)
                    let prefix = try #require(values.first { $0.text == "那我们" && $0.isPartial })
                    let consumed = try #require(prefix.consumedInputCount)
                    #expect(String(input.dropFirst(consumed)).replacingOccurrences(of: "'", with: "") == "zaichaxun")
                }
            }
        }
    }

    private var boundaryEntries: [PinyinLexiconEntry] {
        [
            PinyinLexiconEntry(syllables: ["jia", "yi", "bing"], text: "甲乙丙", upstreamWeight: 1_000),
            PinyinLexiconEntry(syllables: ["ding"], text: "丁", upstreamWeight: 50),
            PinyinLexiconEntry(syllables: ["jia", "yi"], text: "甲已", upstreamWeight: 1_000),
            PinyinLexiconEntry(syllables: ["bing", "ding"], text: "丙丁", upstreamWeight: 5),
        ]
    }

    @Test func tenfoldFrequencyCanOutweighAnAllMultiCharacterSegmentation() {
        let entries = boundaryEntries
        for source in [entries, Array(entries.reversed())] {
            let decoder = PinyinDecoder(entries: source)
            for preview in [false, true] {
                let values = decoder.compositionCandidates(for: "jia'yi'bing'ding", languages: [.simplifiedChinese], preview: preview)
                #expect(values.first?.text == "甲乙丙丁")
            }
        }
    }

    @Test func frequencyBalanceKeepsOrdinaryPhraseBoundaries() {
        for input in ["haodewozhidaole", "hao'de'wo'zhi'dao'le"] {
            for preview in [false, true] {
                let values = PinyinDecoder.standard.compositionCandidates(for: input, languages: [.simplifiedChinese], preview: preview)
                #expect(values.first?.text == "好的我知道了")
            }
        }
    }

    @Test func rareWordsAndExplicitPreferencesRemainAvailable() {
        let decoder = PinyinDecoder(entries: boundaryEntries)
        let input = "jia'yi'bing'ding"
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let learning = LearningProfile(entries: [
            LearnedPreference(input: input, text: "甲已丙丁", language: .simplifiedChinese, strength: 8, lastUsed: now),
        ], now: now)
        #expect(decoder.candidates(for: input).first?.text == "甲乙丙丁")
        let personalized = decoder.compositionCandidates(for: input, languages: [.simplifiedChinese], learning: learning, now: now)
        #expect(personalized.first?.text == "甲已丙丁")
        #expect(personalized.contains { $0.text == "甲乙丙丁" && !$0.isPartial })
        #expect(decoder.candidates(for: "bing'ding").contains { $0.text == "丙丁" })
    }

    @Test func rareLongerFragmentsDoNotAutomaticallyBeatFrequentShorterWords() {
        let decoder = PinyinDecoder(entries: [
            PinyinLexiconEntry(syllables: ["jia", "yi", "bing"], text: "甲已丙", upstreamWeight: 100),
            PinyinLexiconEntry(syllables: ["jia", "yi"], text: "甲乙", upstreamWeight: 1_000_000),
            PinyinLexiconEntry(syllables: ["bing"], text: "丙", upstreamWeight: 5_000_000),
            PinyinLexiconEntry(syllables: ["ding", "wu"], text: "丁戊", upstreamWeight: 100_000),
        ])
        for preview in [false, true] {
            let values = decoder.compositionCandidates(for: "jia'yi'bing'ding'wu", languages: [.simplifiedChinese], preview: preview)
            #expect(values.first?.text == "甲乙丙丁戊")
        }
    }
}
