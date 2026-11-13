import Foundation
import Testing
@testable import SICore

struct CandidateScoringTests {
    private let languages = Set(InputLanguage.allCases)

    @Test func meKeepsChineseAndEnglishMatchesInBothStages() throws {
        let engine = CandidateEngine()
        for values in [engine.candidates(for: "me", languages: languages),
                       engine.previewCandidates(for: "me", languages: languages, learning: LearningProfile(),
                                                dictionary: UserDictionary(), now: .now, context: nil)] {
            let simplified = try #require(values.firstIndex { $0.text == "么" && $0.language == .simplifiedChinese })
            let english = try #require(values.firstIndex { $0.text == "me" && $0.language == .english })
            let traditional = try #require(values.firstIndex { $0.text == "麼" && $0.language == .simplifiedChinese })
            let completion = try #require(values.firstIndex { $0.text == "men" && $0.language == .english })
            #expect([simplified, english, traditional].allSatisfy { !values[$0].hasCompletion })
            #expect(values[completion].hasCompletion)
            #expect(values.last?.isLiteral == true && values.last?.text == "me")
            #expect(Set(values.map(\.id)).count == values.count)
        }
    }

    @Test func exactShortSpellingsRemainSelectableAlongsideCompletions() throws {
        let engine = CandidateEngine()
        for (input, expected, language) in [("ma", "吗", InputLanguage.simplifiedChinese),
                                             ("ne", "呢", .simplifiedChinese), ("man", "慢", .simplifiedChinese)] {
            for values in [engine.candidates(for: input, languages: languages),
                           engine.previewCandidates(for: input, languages: languages, learning: LearningProfile(),
                                                    dictionary: UserDictionary(), now: .now, context: nil)] {
                #expect(values.contains { $0.text == expected && $0.language == language && !$0.hasCompletion && !$0.isPartial })
                #expect(values.contains { $0.language == .english && $0.hasCompletion })
                #expect(values.contains { $0.language == .simplifiedChinese && !$0.isMixed })
                if input == "man" {
                    #expect(values.contains { $0.text == "man" && $0.language == .english && !$0.hasCompletion })
                }
                #expect(values.last?.text == input && values.last?.isLiteral == true)
            }
        }
    }

    @Test func lingHomophonesOutrankTheMixedSplitInPreviewAndFullSearch() throws {
        let engine = CandidateEngine()
        let profile = LearningProfile()
        for values in [engine.candidates(for: "ling", languages: languages),
                       engine.previewCandidates(for: "ling", languages: languages, learning: profile,
                                                dictionary: UserDictionary(), now: .now, context: nil)] {
            let zero = try #require(values.firstIndex { $0.text == "零" && !$0.isPartial })
            let split = try #require(values.firstIndex { $0.text == "里 NG" && $0.isMixed && !$0.isPartial })
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

}
