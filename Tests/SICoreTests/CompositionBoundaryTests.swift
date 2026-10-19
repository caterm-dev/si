import Testing
@testable import SICore

struct CompositionBoundaryTests {
    @Test func smartChinesePunctuationConfirmsTheWholeCandidateExactlyOnce() throws {
        for (typed, expected) in [(".", "。"), (",", "，"), ("!", "！"), ("?", "？"),
                                   (":", "："), (";", "；"), ("(", "（"), ("]", "】")] {
            var session = InputSession()
            session.append("nihao")
            let selected = try #require(session.candidates.first { $0.text == "你好" && !$0.isPartial })
            let boundary = CompositionBoundary.resolve(text: typed, selected: selected, explicitlySelected: false, behavior: .smart)
            #expect(boundary.replacement == expected)
            let commit = session.commitResult(boundary.candidate, reason: .passthrough)
            #expect(commit.text + (boundary.replacement ?? "") == "你好" + expected)
            #expect(session.buffer.isEmpty)
            var profile = LearningProfile()
            let learned = profile.record(commit, learnContext: true)
            #expect(!learned && profile.entries.isEmpty)
        }
    }

    @Test func unselectedEnglishWordsCompletionsAndCodeSeparatorsKeepSpelling() {
        for candidate in [InputCandidate(text: "Mac", language: .english, score: 110),
                          InputCandidate(text: "computer", language: .english, score: 85, hasCompletion: true)] {
            for behavior in [PunctuationBehavior.smart, .confirmCandidate] {
                #expect(CompositionBoundary.resolve(text: ".", selected: candidate, explicitlySelected: false, behavior: behavior).candidate == nil)
                #expect(CompositionBoundary.resolve(text: ".", selected: candidate, explicitlySelected: true, behavior: behavior).candidate == candidate)
            }
        }
        let chinese = InputCandidate(text: "你好", language: .simplifiedChinese, score: 100)
        for text in ["_", "/", "\\", "@", "#", "=", "+", "{", "}", "0", "🙂", ""] {
            #expect(CompositionBoundary.resolve(text: text, selected: chinese, explicitlySelected: true, behavior: .smart).candidate == nil)
        }
    }

    @Test func eachPolicyHasAnExplicitBehaviorAndOriginalChinesePunctuationIsPassedThrough() {
        let selected = InputCandidate(text: "你好", language: .simplifiedChinese, score: 100)
        #expect(CompositionBoundary.resolve(text: ",", selected: selected, explicitlySelected: false, behavior: .asTyped).candidate == nil)
        let unchanged = CompositionBoundary.resolve(text: ",", selected: selected, explicitlySelected: false, behavior: .confirmCandidate)
        #expect(unchanged.candidate == selected && unchanged.replacement == nil)
        let existing = CompositionBoundary.resolve(text: "，", selected: selected, explicitlySelected: false, behavior: .smart)
        #expect(existing.candidate == selected && existing.replacement == nil)
        let tab = CompositionBoundary.resolve(text: "\t", selected: selected, explicitlySelected: false, behavior: .smart)
        #expect(tab.candidate == selected && tab.replacement == nil)
    }

    @Test func mixedEndingsAndCompletionsUseTheCurrentCandidateRatherThanALanguageMode() {
        let englishEnding = InputCandidate(text: "你好world", language: .simplifiedChinese, score: 90, isMixed: true)
        let chineseEnding = InputCandidate(text: "hello中文", language: .simplifiedChinese, score: 90, isMixed: true)
        #expect(CompositionBoundary.resolve(text: ",", selected: englishEnding, explicitlySelected: false, behavior: .smart).replacement == nil)
        #expect(CompositionBoundary.resolve(text: ",", selected: chineseEnding, explicitlySelected: false, behavior: .smart).replacement == "，")
        let completion = InputCandidate(text: "你好world", language: .simplifiedChinese, score: 90, isMixed: true, hasCompletion: true)
        #expect(CompositionBoundary.resolve(text: ",", selected: completion, explicitlySelected: false, behavior: .smart).candidate == nil)
        #expect(CompositionBoundary.resolve(text: ",", selected: completion, explicitlySelected: true, behavior: .smart).candidate == completion)
    }

    @Test func partialCandidatesAndIncompletePersonalCodesCannotDiscardRemainders() {
        let prefix = InputCandidate(text: "你好", language: .simplifiedChinese, score: 74, consumedInputCount: 5)
        #expect(CompositionBoundary.resolve(text: ",", selected: prefix, explicitlySelected: true, behavior: .smart).candidate == nil)
        let personal = InputCandidate(text: "Synthetic Name", language: .english, score: 115, isUserPhrase: true)
        #expect(CompositionBoundary.resolve(text: ",", selected: personal, explicitlySelected: false, behavior: .smart).candidate == personal)
        let incomplete = InputCandidate(text: personal.text, language: .english, score: 80, isUserPhrase: true, hasCompletion: true)
        #expect(CompositionBoundary.resolve(text: ",", selected: incomplete, explicitlySelected: false, behavior: .smart).candidate == nil)
        #expect(CompositionBoundary.resolve(text: ",", selected: incomplete, explicitlySelected: false, behavior: .confirmCandidate).candidate == nil)
        #expect(CompositionBoundary.resolve(text: ",", selected: incomplete, explicitlySelected: true, behavior: .confirmCandidate).candidate == incomplete)
    }
}
