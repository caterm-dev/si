import Foundation
import Testing
@testable import SICore

struct MixedWordBoundaryTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let languages = Set(InputLanguage.allCases)

    @Test(arguments: [1.0, 8, 1_000], [false, true])
    func singleWordLearningDoesNotPromoteASplitEnglishWord(strength: Double, learnEnglish: Bool) throws {
        var entries = [
            LearnedPreference(input: "le", text: "了", language: .simplifiedChinese, strength: strength, lastUsed: now),
        ]
        if learnEnglish {
            entries.append(LearnedPreference(input: "tit", text: "tit", language: .english, strength: strength, lastUsed: now))
        }
        let profile = LearningProfile(entries: entries, now: now)
        let candidates = CandidateEngine().candidates(for: "nihaotitle", languages: languages, learning: profile, now: now)
        let intact = try #require(candidates.firstIndex { $0.text == "你好title" && !$0.isPartial })
        let split = try #require(candidates.firstIndex { $0.text == "你好tit了" && !$0.isPartial })
        #expect(intact < split)
        #expect(candidates.first?.text == "你好title")
        #expect(candidates[split].tokenLearningBonus == 0)
        #expect(candidates.last?.text == "nihaotitle" && candidates.last?.isLiteral == true)
        #expect(candidates == CandidateEngine().candidates(for: "nihaotitle", languages: languages, learning: profile, now: now))
    }

    @Test func explicitWholeChoiceCanStillPreferTheAlternativeSegmentation() throws {
        let profile = LearningProfile(entries: [
            LearnedPreference(input: "nihaotitle", text: "你好tit了", language: .simplifiedChinese,
                              strength: 8, lastUsed: now, isMixed: true),
        ], now: now)
        let candidates = CandidateEngine().candidates(for: "nihaotitle", languages: languages, learning: profile, now: now)
        #expect(candidates.first?.text == "你好tit了")
        #expect(candidates.contains { $0.text == "你好title" && !$0.isPartial })
        #expect(candidates.first?.canLearn == true)
    }

    @Test(arguments: [
        ("nihaoTITLE", "你好TITLE", "你好TIT了"),
        ("nihaotable", "你好table", "你好tab了"),
        ("nihaomaple", "你好maple", "你好map了"),
        ("nihaotitlezhongwen", "你好title中文", "你好tit了中文"),
    ])
    func safeguardAppliesBeyondOneWordAndSurvivesContinuation(input: String, intact: String, split: String) throws {
        let profile = LearningProfile(entries: [
            LearnedPreference(input: "le", text: "了", language: .simplifiedChinese, strength: 8, lastUsed: now),
        ], now: now)
        let candidates = CandidateEngine().candidates(for: input, languages: languages, learning: profile, now: now)
        let intactIndex = try #require(candidates.firstIndex { $0.text == intact && !$0.isPartial })
        let splitIndex = try #require(candidates.firstIndex { $0.text == split && !$0.isPartial })
        #expect(intactIndex < splitIndex)
        #expect(candidates[splitIndex].tokenLearningBonus == 0)
    }

    @Test func aLearnedWholePrefixUsesOnlyItsConsumedSpelling() throws {
        let profile = LearningProfile(entries: [
            LearnedPreference(input: "nihaotitle", text: "你好tit了", language: .simplifiedChinese,
                              strength: 8, lastUsed: now, isMixed: true),
        ], now: now)
        let candidates = CandidateEngine().candidates(for: "nihaotitleshurufa", languages: languages, learning: profile, now: now)
        let prefix = try #require(candidates.first { $0.text == "你好tit了" && $0.consumedInputCount == 10 })
        #expect(profile.rankingScore(for: prefix, input: "nihaotitle", now: now, context: nil) > prefix.rankingScore)
        #expect(profile.rankingScore(for: prefix, input: "nihaotitleshurufa", now: now, context: nil) == prefix.rankingScore)
    }

    @Test(arguments: [("nihaotitlele", "你好title乐观"), ("nihaotit'le", "你好tit乐观")])
    func chineseAfterAnEnglishWordOrExplicitBoundaryStillUsesTokenLearning(input: String, text: String) throws {
        let profile = LearningProfile(entries: [
            LearnedPreference(input: "le", text: "乐观", language: .simplifiedChinese, strength: 8, lastUsed: now),
        ], now: now)
        let candidates = CandidateEngine().candidates(for: input, languages: languages, learning: profile, now: now)
        let candidate = try #require(candidates.first { $0.text == text && !$0.isPartial })
        #expect(candidate.tokenLearningBonus > 0)
    }

    @Test(arguments: [
        ("nibuxiangyaotitle", "你不想要title", "你不想要tit了"),
        ("nixiangyaotitle", "你想要title", "你想要tit了"),
        ("woaizhegetitle", "我爱这个title", "我爱这个tit了"),
    ])
    func longerChinesePrefixesKeepCompleteEnglishWordAhead(input: String, intact: String, split: String) throws {
        let candidates = CandidateEngine().candidates(for: input, languages: Set(InputLanguage.allCases))
        let intactIndex = try #require(candidates.firstIndex { $0.text == intact && !$0.isPartial })
        if let splitIndex = candidates.firstIndex(where: { $0.text == split && !$0.isPartial }) {
            #expect(intactIndex < splitIndex)
        }
    }

    @Test func completeEnglishWordOutranksItsSplitChineseEnding() throws {
        let candidates = CandidateEngine().candidates(for: "nihaotitle", languages: Set(InputLanguage.allCases))
        let intact = try #require(candidates.firstIndex { $0.text == "你好title" && !$0.isPartial })
        let split = try #require(candidates.firstIndex { $0.text == "你好tit了" && !$0.isPartial })
        #expect(intact < split)
    }
}
