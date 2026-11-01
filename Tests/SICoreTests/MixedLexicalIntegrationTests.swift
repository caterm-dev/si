import Foundation
import Testing
@testable import SICore

struct MixedLexicalIntegrationTests {
    private let languages = Set(InputLanguage.allCases)

    @Test(arguments: ["woxiangyaodeploy", "wo'xiang'yao'deploy"])
    func reportedInputProducesTheLeadingMixedWholeCandidateInBothSearchStages(input: String) {
        let engine = CandidateEngine()
        for values in [engine.candidates(for: input, languages: languages),
                       engine.previewCandidates(for: input, languages: languages, learning: LearningProfile(),
                           dictionary: UserDictionary(), now: .now, context: nil)] {
            #expect(values.first { !$0.isPartial }?.text == "我想要 deploy")
            #expect(values.first { !$0.isPartial }?.isMixed == true && values.first { !$0.isPartial }?.hasLiteralSegments == false)
            #expect(values.last?.text == input && values.last?.isLiteral == true)
            #expect(Set(values.map(\.id)).count == values.count)
        }
    }

    @Test func enabledLanguagesAndExactEnglishWordsKeepTheirContracts() {
        let engine = CandidateEngine()
        for enabled: Set<InputLanguage> in [[], [.english], [.simplifiedChinese]] {
            #expect(!engine.candidates(for: "woxiangyaodeploy", languages: enabled).contains { $0.isMixed })
        }
        for word in ["deploy", "DEPLOY", "world", "title", "build"] {
            let values = engine.candidates(for: word, languages: languages)
            #expect(values.first { !$0.isPartial }?.text == word && values.first { !$0.isPartial }?.language == .english && values.first { !$0.isPartial }?.isMixed == false)
            #expect(values.last?.text == word && values.last?.isLiteral == true)
        }
        #expect(engine.candidates(for: "woxianganzhao", languages: languages).first { !$0.isPartial }?.text == "我想按照")
    }

    @Test func caseInterleavingAndFinalEnglishCompletionRemainAvailable() {
        let engine = CandidateEngine()
        for (input, expected) in [("woxiangyaoDEPLOY", "我想要 DEPLOY"), ("deployzhongwen", "deploy 中文"),
                                  ("woaiSwiftshurufa", "我爱 Swift 输入法"), ("nihaogmail", "你好 gmail")] {
            #expect(engine.candidates(for: input, languages: languages).contains {
                $0.text == expected && $0.isMixed && !$0.isPartial && !$0.hasLiteralSegments
            })
        }
        #expect(engine.candidates(for: "woxiangyaodeplo", languages: languages).contains {
            $0.text == "我想要 deploy" && $0.isMixed && $0.hasCompletion && !$0.isPartial
        })
    }

    @Test func explicitSelectionCommitsOnlyCandidateTextAndLiteralReturnKeepsSource() throws {
        var session = InputSession(candidateGeneration: .deferred)
        session.append("woxiangyaodeploy")
        let request = try #require(session.pendingCandidateRequest)
        #expect(session.accept(request.generatePreview()) == true)
        #expect(session.candidates.first { !$0.isPartial }?.text == "我想要 deploy")
        session.resolveCandidates()
        let candidate = try #require(session.candidates.first { $0.text == "我想要 deploy" })
        let result = session.commitResult(candidate, reason: .explicitSelection)
        #expect(result.text == "我想要 deploy" && result.input == "woxiangyaodeploy")
        #expect(session.buffer.isEmpty)
        session.append("woxiangyaodeploy")
        #expect(session.commit() == "woxiangyaodeploy")
    }

    @Test func unicodePrefixConsumptionKeepsExactRemainderAndNoMixedAutomaticEvidence() throws {
        for (input, consumed) in [("lüse'deployzhongwen", 11), ("lu:se'deployzhongwen", 12)] {
            var session = InputSession()
            session.append(input)
            let prefix = try #require(session.candidates.first {
                $0.text == "绿色 deploy" && $0.isMixed && $0.consumedInputCount == consumed
            })
            let result = session.commitResult(prefix, reason: .explicitSelection)
            #expect(result.text == "绿色 deploy" && result.remainingInput == "zhongwen")
            #expect(session.buffer == "zhongwen")
        }
        let values = CandidateEngine().candidates(for: "woxiangyaodeploy", languages: languages,
                                                 includesConfirmationEvidence: true)
        #expect(values.filter(\.isMixed).allSatisfy { $0.confirmationBoundaries.isEmpty })
    }

    @Test func obsoleteMixedResultsCannotRestoreCancelledOrDisabledComposition() throws {
        var session = InputSession(candidateGeneration: .deferred)
        session.append("woxiangyaodeploy")
        let cancelled = try #require(session.pendingCandidateRequest)
        session.reset()
        #expect(session.accept(cancelled.generate()) == false)
        #expect(session.buffer.isEmpty && session.candidates.isEmpty)
        session.append("woxiangyaodeploy")
        let disabled = try #require(session.pendingCandidateRequest)
        session.configure(languages: [.simplifiedChinese])
        #expect(session.accept(disabled.generate()) == false)
        session.resolveCandidates()
        #expect(!session.candidates.contains { $0.isMixed })
    }

    @Test func personalAndUnrecognizedPathsRemainExcludedFromLearningAndContext() throws {
        let dictionary = try UserDictionary(entries: [UserPhrase(input: "gh", text: "GitHub", language: .english)])
        let engine = CandidateEngine()
        let personal = try #require(engine.candidates(for: "nihaogh", languages: languages, dictionary: dictionary)
            .first { $0.text == "你好GitHub" && $0.isMixed && !$0.isPartial })
        #expect(personal.isUserPhrase && !personal.canLearn && personal.tokenLearningBonus == 0)
        #expect(CandidateContext(candidate: personal) == nil)
        let unknown = engine.candidates(for: "nihaozzzqxz", languages: languages)
        let verbatim = try #require(unknown.first { $0.isMixed && $0.hasLiteralSegments })
        #expect(!verbatim.canLearn && CandidateContext(candidate: verbatim) == nil)
        for value in unknown where value.hasLiteralSegments {
            #expect(!value.canLearn && value.tokenLearningBonus == 0)
            #expect(CandidateContext(candidate: value) == nil)
        }
        #expect(unknown.last?.text == "nihaozzzqxz" && unknown.last?.isLiteral == true)
    }
}
