import Foundation
import Testing
@testable import SICore

struct CandidateEngineTests {
    private let engine = CandidateEngine()
    private let languages = Set(InputLanguage.allCases)

    @Test(arguments: ["xianshi", "biruzhege", "danci", "nihaopengyou", "iwanttobuild"])
    func ordinaryCandidatesRetainTheirScoresAndCompeteWithoutTypePriority(input: String) {
        let profile = LearningProfile()
        for enabled: Set<InputLanguage> in [[.simplifiedChinese], languages] {
            for result in [engine.candidates(for: input, languages: enabled),
                           engine.previewCandidates(for: input, languages: enabled, learning: profile,
                                                    dictionary: UserDictionary(), now: .now, context: nil)] {
                let ranked = result.filter { !$0.isLiteral && !$0.isHistory }
                for (left, right) in zip(ranked, ranked.dropFirst()) {
                    #expect(left.rankingScore >= right.rankingScore)
                    if left.rankingScore == right.rankingScore { #expect(left.id < right.id) }
                }
                #expect(result.last?.isLiteral == true && result.last?.text == input)
            }
        }
    }

    @Test func increasingDictionaryFrequencyRaisesAPrefixThroughTheSameWordScore() throws {
        var positions: [Int] = []
        var scores: [Double] = []
        for weight: UInt64 in [100, 2_000_000] {
            let decoder = PinyinDecoder(entries: [
                PinyinLexiconEntry(syllables: ["bi", "ru"], text: "比如", upstreamWeight: weight),
                PinyinLexiconEntry(syllables: ["zhe", "ge"], text: "这个", upstreamWeight: 100),
                PinyinLexiconEntry(syllables: ["bi", "ru", "zhe", "ge"], text: "比如这个", upstreamWeight: 1_000_000),
            ])
            let engine = CandidateEngine(providers: [CompositionProvider(decoder: decoder)])
            let result = engine.candidates(for: "biruzhege", languages: [.simplifiedChinese])
            let index = try #require(result.firstIndex { $0.text == "比如" && $0.consumedInputCount == 4 })
            let whole = try #require(result.firstIndex { $0.text == "比如这个" && !$0.isPartial })
            let standalone = try #require(decoder.candidates(for: "biru").first { $0.text == "比如" })
            #expect(abs(result[index].rankingScore - standalone.rankingScore) < 1e-12)
            positions.append(index - whole)
            scores.append(result[index].rankingScore)
        }
        #expect(positions[0] > 0 && positions[1] < 0)
        #expect(abs(scores[1] - scores[0] - log2(20_000.0)) < 1e-12)
    }

    @Test func wholeAndPrefixCandidatesCompeteByFractionalScoreAcrossSourceSpans() {
        let values = [
            InputCandidate(text: "Whole", language: .english, score: 10, rankingScore: 10.25),
            InputCandidate(text: "Short", language: .english, score: 10,
                           consumedInputCount: 1, rankingScore: 10.75),
            InputCandidate(text: "Long", language: .english, score: 10,
                           consumedInputCount: 4, rankingScore: 10.5),
            InputCandidate(text: "Low", language: .english, score: 9, consumedInputCount: 2),
        ]
        for rows in [values, Array(values.reversed())] {
            let engine = CandidateEngine(providers: [RankedProvider(values: rows)])
            let result = engine.candidates(for: "synthetic", languages: [.english])
            #expect(result.map(\.text) == ["Short", "Long", "Whole", "Low", "synthetic"])
        }
    }

    @Test func prefixLearningUsesConsumedSpellingWithoutAReservedPosition() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let prefix = InputCandidate(text: "Word", language: .english, score: 1, consumedInputCount: 4)
        let whole = InputCandidate(text: "Sentence", language: .english, score: 10)
        let engine = CandidateEngine(providers: [RankedProvider(values: [prefix, whole])])
        let profile = LearningProfile(entries: [
            LearnedPreference(input: "synt", text: "Word", language: .english, strength: 8, lastUsed: now),
        ], now: now)
        let unrelated = LearningProfile(entries: [
            LearnedPreference(input: "synthetic", text: "Word", language: .english, strength: 8, lastUsed: now),
        ], now: now)
        #expect(engine.candidates(for: "synthetic", languages: [.english], now: now).first?.id == whole.id)
        #expect(engine.candidates(for: "synthetic", languages: [.english], learning: profile, now: now).first?.id == prefix.id)
        #expect(engine.candidates(for: "synthetic", languages: [.english], learning: unrelated, now: now).first?.id == whole.id)
    }

    @Test func malformedProvidersCannotReviveDisabledLanguagesOrDuplicateLiteralIdentity() {
        let candidates = CandidateEngine(providers: [MalformedProvider()]).candidates(for: "x", languages: [.english])
        #expect(candidates.count == 1)
        #expect(candidates.first?.text == "x" && candidates.first?.isLiteral == true)
    }

    @Test func ambiguousInputKeepsBothLanguagesAndLiteral() {
        let candidates = engine.candidates(for: "shi", languages: languages)
        #expect(candidates.contains { $0.text == "是" && $0.language == .simplifiedChinese })
        #expect(candidates.contains { $0.text == "ship" && $0.language == .english })
        #expect(candidates.last?.text == "shi")
        #expect(candidates.last?.isLiteral == true)
    }

    @Test func exactEnglishMatchDoesNotHideChinese() {
        let candidates = engine.candidates(for: "he", languages: languages)
        #expect(candidates.first?.text == "he")
        #expect(candidates.contains { $0.text == "和" })
        #expect(candidates.contains { $0.text == "喝" })
    }

    @Test func disabledLanguageDoesNotContributeCandidates() {
        let candidates = engine.candidates(for: "shi", languages: [.english])
        #expect(candidates.allSatisfy { $0.language != .simplifiedChinese })
        #expect(candidates.contains { $0.text == "ship" })
        let chineseOnly = engine.candidates(for: "shi", languages: [.simplifiedChinese])
        #expect(chineseOnly.allSatisfy { $0.language != .english })
    }

    @Test func literalSurvivesUnknownInputAndDisabledProviders() {
        for input in ["unknownword", "https://example.com", "camelCase", "123", "👩🏽‍💻"] {
            let candidates = engine.candidates(for: input, languages: [])
            #expect(candidates.count == 1)
            #expect(candidates.first?.text == input)
            #expect(candidates.first?.isLiteral == true)
        }
        #expect(engine.candidates(for: "", languages: languages).isEmpty)
    }

    @Test func pinyinHandlesCaseAndSyllableSeparator() {
        #expect(engine.candidates(for: "Ni'Hao", languages: languages).contains { $0.text == "你好" })
        #expect(engine.candidates(for: "Ni'Hao", languages: languages).last?.text == "Ni'Hao")
    }

    @Test func rankingIsDeterministicAndCandidatesAreUnique() {
        let first = engine.candidates(for: "shi", languages: languages)
        #expect(first == engine.candidates(for: "shi", languages: languages))
        #expect(Set(first.map(\.id)).count == first.count)
        #expect(first.first?.text == "是")
    }

    @Test func deduplicationPreservesDifferentLanguageIdentities() {
        let english = FixedProvider(language: .english)
        let chinese = FixedProvider(language: .simplifiedChinese)
        let engine = CandidateEngine(providers: [english, english, chinese])
        let result = engine.candidates(for: "same", languages: languages)
        #expect(result.count == 3)
        #expect(Set(result.map(\.id)).count == 3)
    }
}

private struct RankedProvider: CandidateProvider {
    let language = InputLanguage.english
    let values: [InputCandidate]
    func candidates(for input: String) -> [InputCandidate] { values }
}

private struct CompositionProvider: CandidateProvider {
    let language = InputLanguage.simplifiedChinese
    let decoder: PinyinDecoder
    func candidates(for input: String) -> [InputCandidate] {
        decoder.compositionCandidates(for: input, languages: [.simplifiedChinese])
    }
}

private struct FixedProvider: CandidateProvider {
    let language: InputLanguage
    func candidates(for input: String) -> [InputCandidate] {
        [InputCandidate(text: "same", language: language, score: 100)]
    }
}

private struct MalformedProvider: CandidateProvider {
    let language = InputLanguage.english
    func candidates(for input: String) -> [InputCandidate] {
        [InputCandidate(text: "disabled", language: .simplifiedChinese, score: 999),
         InputCandidate(text: input, language: nil, score: 999),
         InputCandidate(text: "", language: .english, score: 999),
         InputCandidate(text: "invalid mixed", language: .english, score: 999, isMixed: true)]
    }
}
