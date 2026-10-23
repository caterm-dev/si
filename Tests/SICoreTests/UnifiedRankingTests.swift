import Foundation
import Testing
@testable import SICore

struct UnifiedRankingTests {
    private let entries = [
        PinyinLexiconEntry(syllables: ["jia"], text: "甲", upstreamWeight: 40),
        PinyinLexiconEntry(syllables: ["yi"], text: "乙", upstreamWeight: 20),
        PinyinLexiconEntry(syllables: ["bing"], text: "丙", upstreamWeight: 10),
        PinyinLexiconEntry(syllables: ["jia", "yi"], text: "甲乙", upstreamWeight: 5),
        PinyinLexiconEntry(syllables: ["jia", "bing"], text: "甲丙", upstreamWeight: 2),
    ]

    @Test func bilingualAndContextDistributionsNormalizeIncludingUnknownOutcomes() {
        let model = LexicalLanguageModel(entries: entries)
        #expect(abs(model.costs.reduce(0) { $0 + exp2(-$1) } - 1) < 1e-11)
        for previous in [0, 1] + model.chineseIDs {
            let mass = model.costs.indices.reduce(0.0) { $0 + exp2(-model.cost(token: $1, after: previous)) }
            #expect(abs(mass - 1) < 1e-11)
        }
    }

    @Test func contextScoresDependOnVocabularyEvidenceRatherThanSelectedCharacterMeanings() {
        let source: [PinyinLexiconEntry] = [
            .init(syllables: ["di"], text: "第", upstreamWeight: 100),
            .init(syllables: ["yi"], text: "一", upstreamWeight: 200),
            .init(syllables: ["er"], text: "二", upstreamWeight: 150),
            .init(syllables: ["ye"], text: "页", upstreamWeight: 20),
            .init(syllables: ["ye"], text: "爷", upstreamWeight: 80),
            .init(syllables: ["di", "yi"], text: "第一", upstreamWeight: 30),
            .init(syllables: ["di", "yi", "ye"], text: "第一页", upstreamWeight: 10),
            .init(syllables: ["er", "ye"], text: "二爷", upstreamWeight: 40),
        ]
        let mapping: [Character: Character] = ["第": "甲", "一": "乙", "二": "丙", "页": "丁", "爷": "戊"]
        let renamed = source.map {
            PinyinLexiconEntry(syllables: $0.syllables, text: String($0.text.map { mapping[$0]! }),
                               upstreamWeight: $0.upstreamWeight!)
        }
        let originalModel = LexicalLanguageModel(entries: source)
        let renamedModel = LexicalLanguageModel(entries: renamed)
        // Relabeling a vocabulary preserves its frequencies and adjacency graph.
        // No selected character or numeral class may introduce extra evidence.
        let originalIDs = [0, 1] + originalModel.chineseIDs
        let renamedIDs = [0, 1] + renamedModel.chineseIDs
        for (previous, renamedPrevious) in zip(originalIDs, renamedIDs) {
            for (token, renamedToken) in zip(originalIDs, renamedIDs) {
                #expect(abs(originalModel.cost(token: token, after: previous)
                            - renamedModel.cost(token: renamedToken, after: renamedPrevious)) < 1e-12)
            }
        }
    }

    @Test func vocabularySuffixesWithoutAWordInitialDoNotLoseProbabilityMass() {
        let model = LexicalLanguageModel(entries: [
            PinyinLexiconEntry(syllables: ["jia", "yi"], text: "甲乙"),
            PinyinLexiconEntry(syllables: ["yi", "bing"], text: "乙丙"),
        ])
        for previous in model.chineseIDs {
            let mass = model.costs.indices.reduce(0.0) { $0 + exp2(-model.cost(token: $1, after: previous)) }
            #expect(abs(mass - 1) < 1e-11)
        }
    }

    @Test func knownCharacterBoundaryInterpolatesWithUnseenWordAndLanguageBackoff() {
        let model = LexicalLanguageModel(entries: entries)
        let jia = model.chineseIDs[0], yi = model.chineseIDs[1], bing = model.chineseIDs[2]
        let switchProbability = RankingCalibration.switchProbability
        // Two distinct observed adjacencies: 甲乙 and 甲丙. C=2,T=2, lambda=1/2.
        // Each observed character receives 1/4 of context mass, distributed over words
        // with that first character in proportion to their unigram prior.
        let expected = (1 - switchProbability) * (0.5 * 20 / 78 + 0.25)
        #expect(abs(exp2(-model.cost(token: yi, after: jia)) - expected) < 1e-12)
        #expect(model.cost(token: yi, after: jia) < model.cost(token: bing, after: jia))
        #expect(abs(exp2(-model.cost(token: 1, after: jia))
                    - switchProbability * EnglishLexicon.entries[0].probability) < 1e-12)
        // 乙 has no observed successor; it backs off without a fabricated pair.
        #expect(abs(exp2(-model.cost(token: bing, after: yi)) - (1 - switchProbability) * 10 / 78) < 1e-12)
    }

    @Test func truncatedSpellingIsAFiniteNormalizedDistributionWithoutScoreTiers() {
        for length in 1...64 {
            let mass = (1...length).reduce(0.0) { $0 + exp2(-WordPrefixChannel.cost(fullLength: length, typedLength: $1)) }
            #expect(abs(mass - 1) < 1e-12)
            for typed in 1..<length {
                #expect(abs(WordPrefixChannel.cost(fullLength: length, typedLength: typed)
                            - WordPrefixChannel.cost(fullLength: length, typedLength: typed + 1) - 1) < 1e-12)
            }
        }
    }

    @Test func alternativePronunciationsCannotBorrowEachOthersFrequency() throws {
        let vocabulary = [PinyinLexiconEntry(syllables: ["a"], text: "呵", upstreamWeight: 0),
                          PinyinLexiconEntry(syllables: ["he"], text: "呵", upstreamWeight: 1000),
                          PinyinLexiconEntry(syllables: ["a"], text: "啊", upstreamWeight: 100)]
        let model = LexicalLanguageModel(entries: vocabulary)
        #expect(abs(exp2(-model.readingCosts[0]) + exp2(-model.readingCosts[1]) - 1) < 1e-12)
        let decoder = PinyinDecoder(entries: vocabulary)
        #expect(decoder.candidates(for: "a").first?.text == "啊")
        #expect(decoder.candidates(for: "he").first?.text == "呵")
    }

    @Test func directEnglishAndMixedEdgesUseTheSameBaseWordAndSpellingCosts() {
        for key in ["abilit", "ability", "develo", "SwiftUI"] {
            for entry in EnglishLexicon.matches(for: key.lowercased()) {
                let expected = 1 + (20 - log(Double(max(1, entry.weight)))) / log(2.0)
                    + WordPrefixChannel.cost(fullLength: entry.length, typedLength: key.count)
                #expect(abs(entry.cost(typedLength: key.count) - expected) < 1e-12)
            }
        }
    }

    @Test func previewCacheAgreesWithUnboundedEnglishRanking() {
        // Independently scan each tested lexical range; cached top eight must agree on score and tie order.
        for prefix in ["a", "s", "sub", "fi", "abil", "abilit", "comput", "info", "sw", "z"] {
            let expected = EnglishLexicon.matches(for: prefix).sorted {
                let a = $0.cost(typedLength: prefix.count), b = $1.cost(typedLength: prefix.count)
                return a == b ? $0.id < $1.id : a < b
            }.prefix(8)
            #expect(EnglishLexicon.previewMatches(for: prefix).map(\.id) == expected.map(\.id))
        }
    }

    @Test func modelInitializationIsIndependentOfVocabularyInsertionOrder() {
        let first = LexicalLanguageModel(entries: entries)
        let second = LexicalLanguageModel(entries: entries.reversed())
        #expect(first.costs == second.costs)
        for a in entries.indices {
            for b in entries.indices {
                let reverseA = entries.count - 1 - a, reverseB = entries.count - 1 - b
                #expect(first.cost(token: first.chineseIDs[a], after: first.chineseIDs[b])
                        == second.cost(token: second.chineseIDs[reverseA], after: second.chineseIDs[reverseB]))
            }
        }
    }
}
