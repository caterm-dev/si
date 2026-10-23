import Foundation
import Testing
@testable import SICore

struct AutomaticConfirmationTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func continuedTypingCommitsStableWordsAndKeepsExactEditableTail() throws {
        var session = makeSession()
        session.append("nihaopengyou", now: start)
        #expect(session.automaticallyConfirm(now: start) == nil)
        session.append("xuexi", now: start.addingTimeInterval(0.2))
        #expect(session.automaticallyConfirm(now: start.addingTimeInterval(0.2)) == nil)
        session.append("zhongwen", now: start.addingTimeInterval(0.4))
        let confirmed = session.automaticallyConfirm(now: start.addingTimeInterval(0.4))
        let commit = try #require(confirmed)
        #expect(commit.text == "你好朋友")
        #expect(commit.input == "nihaopengyou")
        #expect(commit.remainingInput == "xuexizhongwen")
        #expect(session.buffer == commit.remainingInput && session.cursor == session.buffer.count)
        #expect(session.candidates.last?.text == "xuexizhongwen")
        #expect(commit.reason == .automaticConfirmation && commit.reason.learningWeight == 0)
        #expect(session.automaticallyConfirm(now: start.addingTimeInterval(10), afterPause: true) == nil)
        session.deleteBackward()
        #expect(session.buffer == "xuexizhongwe")
        #expect(session.commit() == "xuexizhongwe")
    }

    @Test func pauseConfirmsOnlyPrefixAndNeverDrainsTailWithoutNewInput() throws {
        var session = makeSession()
        session.append("nihaopengyou", now: start)
        #expect(session.hasAutomaticPauseCandidate)
        #expect(session.automaticallyConfirm(now: start.addingTimeInterval(1.7), afterPause: true) == nil)
        let confirmed = session.automaticallyConfirm(now: start.addingTimeInterval(2), afterPause: true)
        let commit = try #require(confirmed)
        #expect(commit.text == "你好" && commit.input == "nihao")
        #expect(session.buffer == "pengyou")
        #expect(!session.hasAutomaticPauseCandidate)
        #expect(session.automaticallyConfirm(now: start.addingTimeInterval(100), afterPause: true) == nil)
    }

    @Test func exactSourceBoundariesIncludeUColonAndTrailingSeparator() throws {
        var session = makeSession()
        session.append("nu:'er'pengyou", now: start)
        let confirmed = session.automaticallyConfirm(now: start.addingTimeInterval(2), afterPause: true)
        let commit = try #require(confirmed)
        #expect(commit.text == "女儿" && commit.input == "nu:'er'")
        #expect(session.buffer == "pengyou")
    }

    @Test func editsNavigationAndConfigurationInvalidatePendingPause() {
        for action in 0..<8 {
            var session = makeSession()
            session.append("nihaopengyou", now: start)
            let revision = session.automaticConfirmationRevision
            switch action {
            case 0: session.deleteBackward()
            case 1: session.moveCursor(by: -1)
            case 2: session.suspendAutomaticConfirmation() // Candidate navigation/expansion.
            case 3: session.breakContext() // Host/focus boundary, even without previous-word context.
            case 4: session.configure(languages: [], automaticConfirmationEnabled: true, now: start)
            case 5: session.configure(languages: [.simplifiedChinese], automaticConfirmationEnabled: false, now: start)
            case 6: session.configure(languages: [.simplifiedChinese], automaticConfirmationEnabled: true,
                                      configurationGeneration: 2, now: start)
            default: session.reset()
            }
            #expect(session.automaticConfirmationRevision != revision)
            #expect(!session.hasAutomaticPauseCandidate)
            #expect(session.automaticallyConfirm(now: start.addingTimeInterval(20), afterPause: true) == nil)
        }
    }

    @Test func freshTypingAfterSelectionMustBuildNewEvidence() {
        var session = makeSession()
        session.append("nihaopengyou", now: start)
        session.suspendAutomaticConfirmation()
        session.append("xuexi", now: start.addingTimeInterval(2))
        #expect(session.automaticallyConfirm(now: start.addingTimeInterval(2)) == nil)
        #expect(session.automaticallyConfirm(now: start.addingTimeInterval(3), afterPause: true) == nil)
        #expect(session.automaticallyConfirm(now: start.addingTimeInterval(4), afterPause: true) != nil)
    }

    @Test func previewsStaleResultsAndOtherClientsCannotCauseAutomaticCommits() throws {
        var session = makeSession(deferred: true)
        session.append("nihaopengyou", now: start)
        let old = try #require(session.pendingCandidateRequest)
        let previewAccepted = session.accept(old.generatePreview(), now: start)
        #expect(previewAccepted)
        #expect(session.automaticallyConfirm(now: start.addingTimeInterval(20), afterPause: true) == nil)
        session.reset()
        session.append("nihaopengyou", now: start.addingTimeInterval(30))
        let oldAccepted = session.accept(old.generate(), now: start.addingTimeInterval(32))
        #expect(!oldAccepted)
        #expect(session.automaticallyConfirm(now: start.addingTimeInterval(32), afterPause: true) == nil)
        var other = makeSession(deferred: true)
        other.append("nihaopengyou", now: start)
        let otherAccepted = other.accept(try #require(session.pendingCandidateRequest).generate(), now: start)
        #expect(!otherAccepted)
        let currentAccepted = session.accept(try #require(session.pendingCandidateRequest).generate(), now: start.addingTimeInterval(31))
        #expect(currentAccepted)
        #expect(session.automaticallyConfirm(now: start.addingTimeInterval(32), afterPause: true) != nil)
        #expect(other.automaticallyConfirm(now: start.addingTimeInterval(100), afterPause: true) == nil)
    }

    @Test func implicitConfirmationNeverTrainsOrBecomesPreviousWordContext() throws {
        var session = makeSession()
        session.configure(languages: [.simplifiedChinese], usesContext: true, automaticConfirmationEnabled: true, now: start)
        session.append("nihaopengyou", now: start)
        let confirmed = session.automaticallyConfirm(now: start.addingTimeInterval(2), afterPause: true)
        let automatic = try #require(confirmed)
        var profile = LearningProfile()
        let learned = profile.record(automatic, now: start, learnContext: true)
        #expect(!learned)
        let manual = session.commitResult(session.candidates.first, reason: .explicitSelection, now: start)
        #expect(manual.context == nil && profile.entries.isEmpty)
    }

    @Test func disagreementInOutputOrSourceBoundaryBlocksEvenLongPauses() {
        let input = "nihaopengyou"
        let boundary = ConfirmationBoundary(sourceCount: 5, outputByteCount: 6)
        let leader = InputCandidate(text: "你好朋友", language: .simplifiedChinese, score: 100,
                                    confirmationBoundaries: [boundary])
        let alternatives = [
            InputCandidate(text: "拟好朋友", language: .simplifiedChinese, score: 99, confirmationBoundaries: [boundary]),
            InputCandidate(text: "你好朋友", language: .simplifiedChinese, score: 99,
                           confirmationBoundaries: [ConfirmationBoundary(sourceCount: 4, outputByteCount: 6)]),
            InputCandidate(text: "nihaopengyou", language: .english, score: 99),
            InputCandidate(text: "你好朋友", language: .simplifiedChinese, score: 99, isUserPhrase: true),
        ]
        for alternative in alternatives {
            #expect(AutomaticConfirmation.prefixes(for: [leader, alternative], input: input,
                                                   learning: LearningProfile(), now: start, context: nil).isEmpty)
        }
    }

    @Test func candidateChangesRestartStabilityInsteadOfCountingOldObservations() {
        let boundary = ConfirmationBoundary(sourceCount: 5, outputByteCount: 6)
        var tracker = AutomaticConfirmation()
        for (offset, text) in ["你好", "拟好", "你好"].enumerated() {
            let input = "nihao" + String(repeating: "a", count: 10 + offset * 10)
            tracker.appended(input: input, atEnd: true, now: start)
            tracker.observe([AutomaticConfirmation.Prefix(
                candidate: InputCandidate(text: text, language: .simplifiedChinese, score: 0,
                                          consumedInputCount: boundary.sourceCount),
                remainingCharacters: 10, remainingLetters: 20)], input: input, now: start)
            #expect(tracker.candidate(now: start, afterPause: false) == nil)
        }
    }

    @Test func aPauseAloneCannotAuthorizeAnIsolatedSingleCharacter() {
        var tracker = AutomaticConfirmation()
        tracker.appended(input: "dishiye", atEnd: true, now: start)
        tracker.observe([AutomaticConfirmation.Prefix(
            candidate: InputCandidate(text: "敌", language: .simplifiedChinese, score: 0, consumedInputCount: 2),
            remainingCharacters: 2, remainingLetters: 5)], input: "dishiye", now: start)
        #expect(!tracker.hasPauseCandidate)
        #expect(tracker.candidate(now: start.addingTimeInterval(100), afterPause: true) == nil)
        tracker.appended(input: "dishiyexuexizhongwen", atEnd: true, now: start.addingTimeInterval(1))
        tracker.observe([AutomaticConfirmation.Prefix(
            candidate: InputCandidate(text: "敌", language: .simplifiedChinese, score: 0, consumedInputCount: 2),
            remainingCharacters: 6, remainingLetters: 17)], input: "dishiyexuexizhongwen", now: start.addingTimeInterval(1))
        #expect(tracker.candidate(now: start.addingTimeInterval(1), afterPause: false)?.text == "敌")
    }

    @Test func codeLiteralUnknownPersonalAndTooShortInputRemainEditable() {
        for input in ["nihao", "nihaop", "Nihaopengyou", "nihao.test", "foo_bar", "zzzzzz", "nihaoQwErTy"] {
            var session = makeSession()
            session.append(input, now: start)
            #expect(session.automaticallyConfirm(now: start.addingTimeInterval(100), afterPause: true) == nil)
            #expect(session.commit() == input)
        }
        var disabled = makeSession(enabled: false)
        disabled.append("nihaopengyouxuexizhongwen", now: start)
        #expect(disabled.automaticallyConfirm(now: start.addingTimeInterval(100), afterPause: true) == nil)
    }

    @Test func unicodeBoundariesAndMalformedProviderMetadataCannotSplitOutputOrCrash() {
        for boundary in [ConfirmationBoundary(sourceCount: -1, outputByteCount: 6),
                         ConfirmationBoundary(sourceCount: 5, outputByteCount: -1),
                         ConfirmationBoundary(sourceCount: 5, outputByteCount: 1_000),
                         ConfirmationBoundary(sourceCount: 5, outputByteCount: 3)] {
            let candidate = InputCandidate(text: "女\u{301}儿朋友", language: .simplifiedChinese, score: 100,
                                            confirmationBoundaries: [boundary])
            #expect(AutomaticConfirmation.prefixes(for: [candidate], input: "nverpengyou",
                                                   learning: LearningProfile(), now: start, context: nil).isEmpty)
        }
        let boundary = ConfirmationBoundary(sourceCount: 4, outputByteCount: 6)
        let leader = InputCandidate(text: "女儿朋友", language: .simplifiedChinese, score: 100,
                                    confirmationBoundaries: [boundary])
        let joined = InputCandidate(text: "女儿\u{301}朋友", language: .simplifiedChinese, score: 99,
                                    confirmationBoundaries: [boundary])
        #expect(AutomaticConfirmation.prefixes(for: [leader, joined], input: "nverpengyou",
                                               learning: LearningProfile(), now: start, context: nil).isEmpty)
    }

    @Test func evidenceDoesNotChangeRankingIDsOrExactOutputAndIsBounded() {
        let engine = CandidateEngine()
        for input in ["nihaopengyou", "womenxuexizhongwen", "woaiSwiftshurufa", String(repeating: "shi", count: 20)] {
            let base = engine.candidates(for: input, languages: Set(InputLanguage.allCases))
            let traced = engine.candidates(for: input, languages: Set(InputLanguage.allCases), includesConfirmationEvidence: true)
            #expect(base.map(\.id) == traced.map(\.id))
            #expect(base.map(\.rankingScore) == traced.map(\.rankingScore))
            #expect(base.map(\.inputScore) == traced.map(\.inputScore))
            #expect(base.map { Array($0.text.utf8) } == traced.map { Array($0.text.utf8) })
            #expect(traced.allSatisfy { $0.confirmationBoundaries.count <= 8 })
        }
    }

    @Test func englishTailProtectionDoesNotDependOnEnabledLanguages() throws {
        let engine = CandidateEngine()
        for languages: Set<InputLanguage> in [[.simplifiedChinese], Set(InputLanguage.allCases)] {
            for input in ["nihaotitle", "nihaotable", "nihaomaple", "nihaotitlezhongwen"] {
                var session = InputSession(engine: engine)
                session.configure(languages: languages, automaticConfirmationEnabled: true)
                session.append(input, now: start)
                #expect(session.automaticallyConfirm(now: start.addingTimeInterval(10), afterPause: true) == nil)
                #expect(session.buffer == input)
            }
            var positive = InputSession(engine: engine)
            positive.configure(languages: languages, automaticConfirmationEnabled: true)
            positive.append("nihaopengyou", now: start)
            let commit = positive.automaticallyConfirm(now: start.addingTimeInterval(2), afterPause: true)
            #expect(commit?.text == "你好" && positive.buffer == "pengyou")
        }
    }

    @Test(arguments: [("nihaopengyouxuexizhongwen", "你好朋友学习中文"), ("womenxuexizhongwen", "我们学习中文")])
    func standardVocabularyActuallyConfirmsDuringTyping(input: String, expected: String) {
        var session = InputSession(candidateGeneration: .deferred)
        session.configure(languages: Set(InputLanguage.allCases), automaticConfirmationEnabled: true)
        var rendered = ""
        var consumed = ""
        for (offset, character) in input.enumerated() {
            let now = start.addingTimeInterval(Double(offset) * 0.08)
            session.append(String(character), now: now)
            if let request = session.pendingCandidateRequest { _ = session.accept(request.generate(), now: now) }
            if let commit = session.automaticallyConfirm(now: now) {
                rendered += commit.text
                consumed += commit.input
                #expect(expected.hasPrefix(rendered))
            }
        }
        #expect(!rendered.isEmpty && !session.buffer.isEmpty)
        #expect(consumed + session.buffer == input)
        #expect(session.candidates.last?.text == session.buffer)
    }

    private func makeSession(enabled: Bool = true, deferred: Bool = false) -> InputSession {
        var session = InputSession(engine: CandidateEngine(providers: [FixtureProvider()]),
                                   candidateGeneration: deferred ? .deferred : .synchronous)
        session.configure(languages: [.simplifiedChinese], automaticConfirmationEnabled: enabled, now: start)
        return session
    }

    private struct FixtureProvider: CandidateProvider {
        let language = InputLanguage.simplifiedChinese
        private let decoder = PinyinDecoder(entries: [
            PinyinLexiconEntry(syllables: ["ni", "hao"], text: "你好"),
            PinyinLexiconEntry(syllables: ["peng", "you"], text: "朋友"),
            PinyinLexiconEntry(syllables: ["xue", "xi"], text: "学习"),
            PinyinLexiconEntry(syllables: ["zhong", "wen"], text: "中文"),
            PinyinLexiconEntry(syllables: ["nv", "er"], text: "女儿"),
        ])
        func candidates(for input: String) -> [InputCandidate] {
            decoder.compositionCandidates(for: input, languages: [language], includesConfirmationEvidence: true)
        }
    }
}
