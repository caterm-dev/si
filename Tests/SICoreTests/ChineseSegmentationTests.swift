import Foundation
import Testing
@testable import SICore

struct ChineseSegmentationTests {
    private struct Provider: CandidateProvider {
        let language = InputLanguage.simplifiedChinese
        let decoder: PinyinDecoder
        func candidates(for input: String) -> [InputCandidate] {
            decoder.compositionCandidates(for: input, languages: [.simplifiedChinese])
        }
    }

    @Test func ambiguousFullSpellingCompetesInPreviewAndFinalSearch() throws {
        for input in ["woxianganzhao", "wo'xiang'an'zhao", "woxiang'anzhao", "wo'woxianganzhao"] {
            let expected = input.hasPrefix("wo'wo") ? "我我想按照" : "我想按照"
            for languages: Set<InputLanguage> in [[.simplifiedChinese], Set(InputLanguage.allCases)] {
                var session = InputSession(candidateGeneration: .deferred)
                session.configure(languages: languages)
                session.append(input)
                let request = try #require(session.pendingCandidateRequest)
                for values in [request.generatePreview().candidates, request.generate().candidates] {
                    #expect(values.first?.text == expected && values.first?.isPartial == false)
                    #expect(values.last?.text == input && values.last?.isLiteral == true)
                }
            }
        }
    }

    private var entries: [PinyinLexiconEntry] {
        [
            PinyinLexiconEntry(syllables: ["wo"], text: "我", upstreamWeight: 10_000),
            PinyinLexiconEntry(syllables: ["xiang"], text: "想", upstreamWeight: 10_000),
            PinyinLexiconEntry(syllables: ["an", "zhao"], text: "按照", upstreamWeight: 10_000),
            PinyinLexiconEntry(syllables: ["xian"], text: "先", upstreamWeight: 1_000),
            PinyinLexiconEntry(syllables: ["gan", "zhao"], text: "感召", upstreamWeight: 1_000),
        ]
    }

    @Test func sentenceScoresChooseTheCutAndExplicitSeparatorsConstrainIt() {
        for rows in [entries, Array(entries.reversed())] {
            let decoder = PinyinDecoder(entries: rows)
            #expect(decoder.candidates(for: "woxianganzhao").first?.text == "我想按照")
            #expect(decoder.candidates(for: "wo'xian'gan'zhao").first?.text == "我先感召")
            #expect(decoder.candidates(for: "wo'xiang'an'zhao").first?.text == "我想按照")
        }
    }

    @Test func deliberateLearningCanChooseAnotherCutAndClearingRestoresBaseOrder() {
        let decoder = PinyinDecoder(entries: entries)
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        var learning = LearningProfile(entries: [
            LearnedPreference(input: "woxianganzhao", text: "我先感召", language: .simplifiedChinese,
                              strength: 8, lastUsed: now),
        ], now: now)
        let values = decoder.compositionCandidates(for: "woxianganzhao", languages: [.simplifiedChinese],
                                                  learning: learning, now: now)
        #expect(values.first?.text == "我先感召")
        #expect(values.contains { $0.text == "我想按照" && !$0.isPartial })
        learning.removeAll()
        #expect(decoder.compositionCandidates(for: "woxianganzhao", languages: [.simplifiedChinese],
                                             learning: learning, now: now).first?.text == "我想按照")
    }

    @Test func alternativeLexicalPrefixesCommitExactSourceBoundaries() throws {
        let decoder = PinyinDecoder(entries: entries + [
            PinyinLexiconEntry(syllables: ["wo", "xiang"], text: "我想", upstreamWeight: 10_000),
            PinyinLexiconEntry(syllables: ["lv", "xiang"], text: "吕想", upstreamWeight: 10_000),
        ])
        for (input, text, consumed) in [("woxianganzhao", "我想", 7),
                                        ("lüxianganzhao", "吕想", 7),
                                        ("lu:xianganzhao", "吕想", 8),
                                        ("lu:xiang'anzhao", "吕想", 9)] {
            let values = decoder.compositionCandidates(for: input, languages: [.simplifiedChinese])
            let prefix = try #require(values.first { $0.text == text && $0.isLexicalPrefix })
            #expect(prefix.consumedInputCount == consumed)
            var session = InputSession(engine: CandidateEngine(providers: [Provider(decoder: decoder)]))
            session.configure(languages: [.simplifiedChinese])
            session.append(input)
            let commit = session.commitResult(prefix, reason: .explicitSelection)
            #expect(commit.text == text && commit.input == String(input.prefix(consumed)))
            #expect(session.buffer == "anzhao")
        }
    }

    @Test func evidenceDoesNotChangeAmbiguousResults() {
        let engine = CandidateEngine()
        for input in ["woxianganzhao", "woxianganzhaozhege", "wo'xian'gan'zhao"] {
            let plain = engine.candidates(for: input, languages: [.simplifiedChinese])
            let traced = engine.candidates(for: input, languages: [.simplifiedChinese], includesConfirmationEvidence: true)
            #expect(plain.map(\.id) == traced.map(\.id))
            #expect(plain.map(\.rankingScore) == traced.map(\.rankingScore))
        }
    }

    @Test func tiedCutsVetoDisputedAutomaticConfirmationBoundaries() throws {
        let decoder = PinyinDecoder(entries: entries.map {
            PinyinLexiconEntry(syllables: $0.syllables, text: $0.text, upstreamWeight: 1_000)
        })
        let values = decoder.compositionCandidates(for: "woxianganzhao", languages: [.simplifiedChinese],
                                                  includesConfirmationEvidence: true)
        let first = try #require(values.first)
        #expect(first.confirmationBoundaries.map(\.sourceCount) == [2])
    }

    @Test func minimumCutsStayBoundedAndHonorSeparators() throws {
        let input = try #require(PinyinInput(String(repeating: "fangan", count: 10)))
        let cuts = ChineseSyllables.alternatives(input, minimumOnly: true)
        #expect(cuts.count == 32)
        #expect(cuts.allSatisfy { $0.count == 20 && $0.joined() == String(input.letters) })
        #expect(cuts == ChineseSyllables.alternatives(input, minimumOnly: true))
        let constrained = try #require(PinyinInput("wo'xiang'an'zhao"))
        #expect(ChineseSyllables.alternatives(constrained, minimumOnly: true) == [["wo", "xiang", "an", "zhao"]])
    }
}
