import Foundation
import Testing
@testable import SICore

struct CompositionLearningTests {
    private struct Provider: CandidateProvider {
        let language = InputLanguage.simplifiedChinese
        func candidates(for input: String) -> [InputCandidate] {
            switch input {
            case "suocheng": [InputCandidate(text: "锁", language: language, score: -10,
                                              consumedInputCount: 3, lexicalTokenCount: 1)]
            case "cheng": [InputCandidate(text: "成", language: language, score: -20, lexicalTokenCount: 1)]
            default: []
            }
        }
    }

    private func session(enabled: Bool = true) -> InputSession {
        var result = InputSession(engine: CandidateEngine(providers: [Provider()]))
        result.configure(languages: [.simplifiedChinese], compositionLearningEnabled: enabled)
        // Exercise ordinary character-by-character typing as well as the selection chain.
        for character in "suocheng" { result.append(String(character)) }
        return result
    }

    private func select(_ text: String, in session: inout InputSession,
                        reason: CommitReason = .explicitSelection) throws -> InputCommit {
        let candidate = try #require(session.candidates.first { $0.text == text })
        return session.commitResult(candidate, reason: reason)
    }

    @Test(arguments: [true, false])
    func completedManualChainRetainsPiecesAndPromotesWholeSpelling(correctFirst: Bool) throws {
        var session = session()
        var memory = ApplicationMemory()
        let first = try select("锁", in: &session, reason: correctFirst ? .explicitSelection : .defaultAcceptance)
        #expect(first.input == "suo" && first.remainingInput == "cheng")
        #expect({ session.recordSuccessfulCommit(first) == nil }())
        #expect({ memory.recordVocabulary(first) }())
        // A snapshot refresh after learning a prefix must preserve the active chain.
        session.configure(languages: [.simplifiedChinese], applicationMemory: memory.snapshot(vocabularyEnabled: true),
                          compositionLearningEnabled: true)
        let last = try select("成", in: &session, reason: correctFirst ? .defaultAcceptance : .explicitSelection)
        let whole = try #require({ session.recordSuccessfulCommit(last) }())
        #expect(whole.input == "suocheng" && whole.text == "锁成" && whole.remainingInput.isEmpty)
        #expect(whole.reason == .explicitSelection && whole.candidate?.lexicalTokenCount == 2)
        #expect(whole.candidate?.rankingScore == -30)
        #expect({ memory.recordVocabulary(last) }())
        #expect({ memory.recordVocabulary(whole) }())
        #expect(memory.vocabulary.count == 3)
        let snapshot = memory.snapshot(vocabularyEnabled: true)
        let candidates = CandidateEngine(providers: [Provider()]).candidates(for: "suocheng", languages: [.simplifiedChinese],
                                                                          applicationMemory: snapshot)
        #expect(candidates.first?.text == "锁成")
        #expect(candidates.last?.text == "suocheng")
        #expect(snapshot.preferredCandidateID(for: "suo", languages: [.simplifiedChinese]) != whole.candidate?.id)
    }

    @Test func allFirstChoicesRemainNeutralAndSingleCommitIsNotDuplicated() throws {
        var session = session()
        let first = try select("锁", in: &session, reason: .defaultAcceptance)
        #expect({ session.recordSuccessfulCommit(first) == nil }())
        let last = try select("成", in: &session, reason: .defaultAcceptance)
        let whole = try #require({ session.recordSuccessfulCommit(last) }())
        var memory = ApplicationMemory()
        #expect({ memory.recordVocabulary(whole) }())
        #expect(memory.vocabulary.first?.lastSelected == nil)
        #expect(memory.snapshot(vocabularyEnabled: true).vocabularyCandidates(for: "suocheng", languages: [.simplifiedChinese], now: .now).isEmpty)
        session.append("cheng")
        let single = try select("成", in: &session)
        #expect({ session.recordSuccessfulCommit(single) == nil }())
    }

    @Test(arguments: ["edit", "append", "reset", "context", "configuration", "consent", "failed"])
    func interruptedChainsNeverLearnTheWholeSpelling(interruption: String) throws {
        var session = session()
        let first = try select("锁", in: &session)
        #expect({ session.recordSuccessfulCommit(first) == nil }())
        switch interruption {
        case "edit": session.deleteBackward(); session.append("g")
        case "append": session.append("x"); session.deleteBackward()
        case "reset": session.reset(); session.append("cheng")
        case "context": session.breakContext()
        case "configuration": session.configure(languages: [.simplifiedChinese], contextGeneration: 1, compositionLearningEnabled: true)
        case "consent":
            session.configure(languages: [.simplifiedChinese], compositionLearningEnabled: false)
            session.configure(languages: [.simplifiedChinese], compositionLearningEnabled: true)
        default: session.discardCompositionLearning()
        }
        let last = try select("成", in: &session)
        #expect({ session.recordSuccessfulCommit(last) == nil }())
    }

    @Test func disabledLearningAndUnacknowledgedPrefixesDoNotAccumulate() throws {
        var disabled = session(enabled: false)
        let first = try select("锁", in: &disabled)
        #expect({ disabled.recordSuccessfulCommit(first) == nil }())
        let last = try select("成", in: &disabled)
        #expect({ disabled.recordSuccessfulCommit(last) == nil }())
        var unacknowledged = session()
        _ = try select("锁", in: &unacknowledged)
        let final = try select("成", in: &unacknowledged)
        #expect({ unacknowledged.recordSuccessfulCommit(final) == nil }())
    }

    @Test(arguments: [CommitReason.literal, .passthrough, .automaticConfirmation, .aiCompletion])
    func excludedReasonsBreakTheChain(reason: CommitReason) {
        var chain = CompositionLearning()
        let prefix = InputCandidate(text: "锁", language: .simplifiedChinese, score: 1, consumedInputCount: 3)
        #expect({ chain.record(InputCommit(input: "suo", candidate: prefix, reason: reason, remainingInput: "cheng")) == nil }())
        #expect({ chain.record(InputCommit(input: "cheng", candidate: InputCandidate(text: "成", language: .simplifiedChinese, score: 1),
                                        reason: .explicitSelection)) == nil }())
    }

    @Test(arguments: ["personal", "verbatim", "punctuation", "literal", "oversized"])
    func excludedCandidatesAndSizeLimitsBreakTheChain(kind: String) {
        var chain = CompositionLearning()
        let prefix = InputCandidate(text: kind == "oversized" ? String(repeating: "锁", count: 171) : "锁",
                                    language: kind == "literal" ? nil : .simplifiedChinese, score: 1,
                                    isUserPhrase: kind == "personal", hasLiteralSegments: kind == "verbatim",
                                    consumedInputCount: 3,
                                    punctuationLanguage: kind == "punctuation" ? .simplifiedChinese : nil)
        #expect({ chain.record(InputCommit(input: "suo", candidate: prefix, reason: .explicitSelection, remainingInput: "cheng")) == nil }())
        #expect({ chain.record(InputCommit(input: "cheng", candidate: InputCandidate(text: "成", language: .simplifiedChinese, score: 1),
                                        reason: .explicitSelection)) == nil }())
    }

    @Test func exactAliasSeparatorAndOutputBytesSurviveMultiplePieces() throws {
        var chain = CompositionLearning()
        let parts = [("Lu:'", "绿", "secheng", InputLanguage.simplifiedChinese),
                     ("se", "色", "cheng", .simplifiedChinese), ("cheng", "成", "", .simplifiedChinese)]
        var whole: InputCommit?
        for (input, text, remainder, language) in parts {
            whole = chain.record(InputCommit(input: input, candidate: InputCandidate(text: text, language: language, score: 1,
                consumedInputCount: remainder.isEmpty ? nil : input.count), reason: .explicitSelection, remainingInput: remainder))
        }
        let result = try #require(whole)
        #expect(result.input.utf8.elementsEqual("Lu:'secheng".utf8))
        #expect(result.text.utf8.elementsEqual("绿色成".utf8))
        var memory = ApplicationMemory()
        #expect({ memory.recordVocabulary(result) }())
        #expect(memory.vocabulary.first?.preference.input == "lv'secheng")
    }

    @Test func mixedChainsKeepActualConcatenatedOutputAndLanguageIdentity() throws {
        var chain = CompositionLearning()
        let prefix = InputCandidate(text: "hello", language: .english, score: 1, consumedInputCount: 5)
        #expect({ chain.record(InputCommit(input: "hello", candidate: prefix, reason: .explicitSelection, remainingInput: "cheng")) == nil }())
        let whole = try #require({ chain.record(InputCommit(input: "cheng",
            candidate: InputCandidate(text: "成", language: .simplifiedChinese, score: 1), reason: .defaultAcceptance)) }())
        #expect(whole.text == "hello成")
        #expect(whole.candidate?.isMixed == true && whole.candidate?.language == .simplifiedChinese)
    }

    @Test(arguments: ["source", "boundary"])
    func inconsistentSourceOrConsumptionCannotProduceAnAggregate(kind: String) {
        var chain = CompositionLearning()
        let first = InputCommit(input: "suo", candidate: InputCandidate(text: "锁", language: .simplifiedChinese, score: 1,
            consumedInputCount: kind == "boundary" ? 2 : 3), reason: .explicitSelection, remainingInput: "cheng")
        let prefixResult = chain.record(first)
        #expect(prefixResult == nil)
        let final = InputCommit(input: kind == "source" ? "chen" : "cheng",
            candidate: InputCandidate(text: "成", language: .simplifiedChinese, score: 1), reason: .explicitSelection)
        let whole = chain.record(final)
        #expect(whole == nil)
    }

    @Test func concatenationPreservesUnicodeBytesAcrossFragmentBoundaries() throws {
        var chain = CompositionLearning()
        let first = InputCommit(input: "a", candidate: InputCandidate(text: "e", language: .english, score: 1,
            consumedInputCount: 1), reason: .explicitSelection, remainingInput: "b")
        let prefixResult = chain.record(first)
        #expect(prefixResult == nil)
        let final = InputCommit(input: "b", candidate: InputCandidate(text: "\u{301}", language: .english, score: 1),
                                reason: .defaultAcceptance)
        let result = chain.record(final)
        let whole = try #require(result)
        #expect(whole.text.utf8.elementsEqual("e\u{301}".utf8))
        #expect(!whole.text.utf8.elementsEqual("é".utf8))
    }
}
