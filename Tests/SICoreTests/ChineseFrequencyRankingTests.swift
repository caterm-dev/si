import Foundation
import Testing
@testable import SICore

struct ChineseFrequencyRankingTests {
    @Test(arguments: ["taiguo", "tai'guo"])
    func thailandRanksAheadOfHomophone(input: String) throws {
        for languages: Set<InputLanguage> in [[.simplifiedChinese], Set(InputLanguage.allCases)] {
            var session = InputSession(candidateGeneration: .deferred)
            session.configure(languages: languages)
            session.append(input)
            let request = try #require(session.pendingCandidateRequest)
            for candidates in [request.generatePreview().candidates, request.generate().candidates] {
                let matches = candidates.filter {
                    $0.language == .simplifiedChinese && !$0.isPartial && ($0.text == "泰国" || $0.text == "太过")
                }
                #expect(matches.map(\.text) == ["泰国", "太过"])
            }
        }
    }

    @Test func previousOccurrenceWeightAppliesEquallyToDirectAndPrefixChoices() throws {
        let entry = try #require(ChineseLexicon.standard.exactMatches(["shang", "ci"]).first { $0.text == "上次" })
        #expect(entry.weight == 40_000)
        let baseline = PinyinDecoder(entries: [
            PinyinLexiconEntry(syllables: ["shang", "ci"], text: "上次", upstreamWeight: 21_766),
        ])
        let engine = CandidateEngine()
        for input in ["shangci", "shang'ci"] {
            let previous = try #require(baseline.candidates(for: input).first { $0.text == "上次" })
            for languages: Set<InputLanguage> in [[.simplifiedChinese], Set(InputLanguage.allCases)] {
                let direct = try #require(engine.candidates(for: input, languages: languages).first {
                    $0.text == "上次" && !$0.isPartial
                })
                #expect(abs(direct.rankingScore - previous.rankingScore - 1.05 * log2(40_000.0 / 21_766)) < 1e-12)
                let requestInput = input + "bi"
                for values in [engine.candidates(for: requestInput, languages: languages),
                               engine.previewCandidates(for: requestInput, languages: languages, learning: LearningProfile(),
                                   dictionary: UserDictionary(), now: .now, context: nil)] {
                    let prefix = try #require(values.first { $0.text == "上次" && $0.consumedInputCount == input.count })
                    #expect(abs(prefix.rankingScore - direct.rankingScore) < 1e-12)
                    #expect(values.last?.text == requestInput && values.last?.isLiteral == true)
                }
            }
        }
    }

    @Test(arguments: [UInt64(20_000), 40_000])
    func frequencyAdvantageCompetesWithAnAdditionalWordAndTwoCharacters(middleWeight: UInt64) {
        let entries = [
            PinyinLexiconEntry(syllables: ["jia", "yi"], text: "甲乙", upstreamWeight: 7_000),
            PinyinLexiconEntry(syllables: ["bing", "ding"], text: "丙丁", upstreamWeight: 1_000),
            PinyinLexiconEntry(syllables: ["jia"], text: "戊", upstreamWeight: 6_000_000),
            PinyinLexiconEntry(syllables: ["yi", "bing"], text: "己庚", upstreamWeight: middleWeight),
            PinyinLexiconEntry(syllables: ["ding"], text: "辛", upstreamWeight: 500_000),
        ]
        for order in [entries, Array(entries.reversed())] {
            let decoder = PinyinDecoder(entries: order)
            for preview in [false, true] {
                let values = decoder.compositionCandidates(for: "jia'yi'bing'ding", languages: [.simplifiedChinese],
                                                           preview: preview)
                let expected = middleWeight == 20_000 ? "甲乙丙丁" : "戊己庚辛"
                #expect(values.first?.text == expected)
                #expect(values.contains { $0.text == "甲乙丙丁" && !$0.isPartial })
                #expect(values.contains { $0.text == "戊己庚辛" && !$0.isPartial })
                #expect(values == decoder.compositionCandidates(for: "jia'yi'bing'ding", languages: [.simplifiedChinese],
                                                               preview: preview))
            }
        }
    }

    @Test func comparisonPhraseLeadsAmongCompleteConversionsInBothSearchStages() throws {
        for input in ["heshangcibi", "he'shang'ci'bi"] {
            for languages: Set<InputLanguage> in [[.simplifiedChinese], Set(InputLanguage.allCases)] {
                var session = InputSession(candidateGeneration: .deferred)
                session.configure(languages: languages)
                session.append(input)
                let request = try #require(session.pendingCandidateRequest)
                let preview = request.generatePreview()
                let full = request.generate()
                for values in [preview.candidates, full.candidates] {
                    let first = try #require(values.first { !$0.isPartial })
                    #expect(first.text == "和上次比")
                    #expect(!first.isPartial && !first.isMixed && !first.isUserPhrase)
                    let alternative = try #require(values.first { $0.text == "和尚刺鼻" && !$0.isPartial })
                    #expect(first.rankingScore > alternative.rankingScore)
                    #expect(first.inputScore == first.rankingScore)
                    #expect(values.last?.text == input && values.last?.isLiteral == true)
                }
                #expect(session.accept(full) == true)
                let selected = try #require(session.candidates.first { $0.text == "和上次比" && !$0.isPartial })
                let commit = session.commitResult(selected, reason: .explicitSelection)
                #expect(commit.text == "和上次比" && commit.input == input)
                #expect(session.buffer.isEmpty)
            }
        }
    }

    @Test func frequentCharactersCanOutweighFewerLowFrequencyWords() {
        let entries = [
            PinyinLexiconEntry(syllables: ["jia", "yi"], text: "甲乙", upstreamWeight: 7_052),
            PinyinLexiconEntry(syllables: ["bing", "ding"], text: "丙丁", upstreamWeight: 942),
            PinyinLexiconEntry(syllables: ["jia"], text: "戊", upstreamWeight: 6_630_848),
            PinyinLexiconEntry(syllables: ["yi", "bing"], text: "己庚", upstreamWeight: 21_766),
            PinyinLexiconEntry(syllables: ["ding"], text: "辛", upstreamWeight: 527_712),
        ]
        for order in [entries, Array(entries.reversed())] {
            let decoder = PinyinDecoder(entries: order)
            for preview in [false, true] {
                let values = decoder.compositionCandidates(for: "jia'yi'bing'ding", languages: [.simplifiedChinese],
                                                           preview: preview)
                #expect(values.first?.text == "戊己庚辛")
                #expect(values.contains { $0.text == "甲乙丙丁" && !$0.isPartial })
                #expect(values == decoder.compositionCandidates(for: "jia'yi'bing'ding", languages: [.simplifiedChinese],
                                                               preview: preview))
            }
        }
    }

    @Test func frequentNaturalWordsBeatCrossBoundaryFragmentsInBothSearchStages() throws {
        for input in ["nawomenzaichaxun", "na'wo'men'zai'cha'xun"] {
            for languages: Set<InputLanguage> in [[.simplifiedChinese], Set(InputLanguage.allCases)] {
                var session = InputSession(candidateGeneration: .deferred)
                session.configure(languages: languages)
                session.append(input)
                let request = try #require(session.pendingCandidateRequest)
                for values in [request.generatePreview().candidates, request.generate().candidates] {
                    let first = try #require(values.first { !$0.isPartial })
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
