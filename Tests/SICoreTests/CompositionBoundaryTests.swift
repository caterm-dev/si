import Testing
@testable import SICore

struct CompositionBoundaryTests {
    @Test func asciiPeriodRemainsEditableWithoutConfirmingDomainLabels() throws {
        for behavior in PunctuationBehavior.allCases {
            for input in ["nihao", "shi", "example", "Gmail", "MyTool"] {
                var session = InputSession()
                session.append(input)
                let selected = try #require(session.candidates.first)
                let boundary = CompositionBoundary.resolve(text: ".", selected: selected,
                                                           explicitlySelected: false, behavior: behavior)
                #expect(boundary.candidate == nil && boundary.replacement == nil)
                #expect(boundary.continuesComposition)
                #expect(CompositionBoundary.keepsInComposition(text: ".", behavior: behavior))
                session.append(".")
                session.append("test")
                #expect(session.buffer == input + ".test")
                #expect(session.candidates.last?.text == session.buffer && session.candidates.last?.isLiteral == true)
                let commit = session.commitResult(reason: .literal)
                #expect(commit.text == input + ".test")
                #expect(session.buffer.isEmpty)
                var learning = LearningProfile()
                #expect(learning.record(commit, learnContext: true) == false)
                #expect(learning.entries.isEmpty)
            }
        }
    }

    @Test func defaultSymbolsRemainInCompositionAndExcludeControlKeys() {
        let symbols = ".,;:!?()[]{}<>/\\@#$_=+-*%&|~`\"'，。；：！？（）【】「」￥≤©🙂❤️👩🏽‍💻"
        for symbol in symbols {
            let text = String(symbol)
            #expect(CompositionBoundary.keepsInComposition(text: text, behavior: .asTyped))
            let resolution = CompositionBoundary.resolve(text: text,
                selected: InputCandidate(text: "你好", language: .simplifiedChinese, score: 100),
                explicitlySelected: true, behavior: .asTyped)
            #expect(resolution.continuesComposition && resolution.candidate == nil && resolution.replacement == nil)
        }
        for text in ["", " ", "\t", "\n", "\r", "\u{1b}", "1", "a", ".\n"] {
            #expect(!CompositionBoundary.keepsInComposition(text: text, behavior: .asTyped))
        }
    }

    @Test func symbolCompositionsKeepExactSpellingAcrossLanguagesAndExplicitConfirmation() throws {
        for languages: Set<InputLanguage> in [[], [.english], [.simplifiedChinese], Set(InputLanguage.allCases)] {
            for input in ["example.com", "user@example.com", "foo/bar", "My_Type+=Value", "nihao,world", "nihao。"] {
                var session = InputSession()
                session.configure(languages: languages)
                for character in input { session.append(String(character)) }
                #expect(session.buffer == input && session.cursorUTF16Offset == input.utf16.count)
                let literal = try #require(session.candidates.last)
                #expect(literal.isLiteral && literal.text == input)
                let commit = session.commitResult(literal, reason: .explicitSelection)
                #expect(commit.text == input && session.buffer.isEmpty)
                var profile = LearningProfile()
                let learned = profile.record(commit, learnContext: true)
                #expect(!learned && profile.entries.isEmpty)
            }
        }
    }

    @Test func symbolsStayEditableAndObsoleteAsyncResultsCannotRestoreOldCandidates() throws {
        var session = InputSession(candidateGeneration: .deferred)
        session.append("nihao")
        let staleRequest = try #require(session.pendingCandidateRequest)
        let staleCandidate = try #require(staleRequest.generate().candidates.first { $0.text == "你好" })
        session.append(".")
        #expect(session.accept(staleRequest.generate()) == false)
        session.append("test")
        session.moveCursor(by: -4)
        session.deleteBackward()
        #expect(session.buffer == "nihaotest")
        session.append("@")
        session.deleteForward()
        session.append("T")
        #expect(session.buffer == "nihao@Test")
        let current = try #require(session.pendingCandidateRequest)
        #expect(session.accept(current.generatePreview()) == true)
        #expect(session.candidates.last?.text == "nihao@Test")
        #expect(session.commit(staleCandidate) == "nihao@Test")
        let acceptedAfterCommit = session.accept(current.generate())
        #expect(!acceptedAfterCommit && session.buffer.isEmpty)
        session.append("example.com")
        let cancelled = try #require(session.pendingCandidateRequest)
        session.reset()
        let acceptedAfterCancel = session.accept(cancelled.generate())
        #expect(!acceptedAfterCancel && session.candidates.isEmpty)
    }

    @Test func asciiPeriodNeverConfirmsEvenAnActivelySelectedCandidate() {
        let candidates = [
            InputCandidate(text: "你好", language: .simplifiedChinese, score: 100),
            InputCandidate(text: "Mac", language: .english, score: 110),
            InputCandidate(text: "hello中文", language: .simplifiedChinese, score: 90, isMixed: true),
            InputCandidate(text: "Synthetic Name", language: .english, score: 115, isUserPhrase: true),
        ]
        for behavior in PunctuationBehavior.allCases {
            for candidate in candidates {
                for explicit in [false, true] {
                    let boundary = CompositionBoundary.resolve(text: ".", selected: candidate,
                                                               explicitlySelected: explicit, behavior: behavior)
                    #expect(boundary.candidate == nil && boundary.replacement == nil)
                }
            }
        }
    }

    @Test func fullwidthChinesePeriodStillConfirmsAndPassesThroughOnce() throws {
        for behavior in [PunctuationBehavior.smart, .confirmCandidate] {
            var session = InputSession()
            session.append("nihao")
            let selected = try #require(session.candidates.first { $0.text == "你好" })
            let boundary = CompositionBoundary.resolve(text: "。", selected: selected,
                                                       explicitlySelected: false, behavior: behavior)
            #expect(boundary.candidate == selected && boundary.replacement == nil)
            let commit = session.commitResult(boundary.candidate, reason: .passthrough)
            #expect(commit.text + (boundary.replacement ?? "。") == "你好。")
            #expect(session.buffer.isEmpty)
        }
    }

    @Test func smartChinesePunctuationConfirmsTheWholeCandidateExactlyOnce() throws {
        for (typed, expected) in [(",", "，"), ("!", "！"), ("?", "？"),
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
                #expect(CompositionBoundary.resolve(text: ",", selected: candidate, explicitlySelected: false, behavior: behavior).candidate == nil)
                #expect(CompositionBoundary.resolve(text: ",", selected: candidate, explicitlySelected: true, behavior: behavior).candidate == candidate)
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
