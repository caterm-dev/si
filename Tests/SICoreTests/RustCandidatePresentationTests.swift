import Testing
@testable import SICore

struct RustCandidatePresentationTests {
    @Test func canonicalIdentityDeduplicationPreservesWinningOutputAndEvidence() throws {
        let direct = InputCandidate(text: "é", language: .english, score: -20, lexicalTokenCount: 1)
        let composed = InputCandidate(text: "e\u{301}", language: .english, score: -10,
                                      lexicalTokenCount: 2,
                                      confirmationBoundaries: [ConfirmationBoundary(sourceCount: 3, outputByteCount: 3)])
        let chinese = InputCandidate(text: "é", language: .simplifiedChinese, score: -10, lexicalTokenCount: 1)
        let correction = InputCandidate(text: "é", language: .english, score: 100, isPinyinCorrection: true)
        for order in [false, true] {
            let result = RustCandidatePresentation.merge([direct, composed, chinese, correction], input: "abc",
                languages: Set(InputLanguage.allCases), coverageOrder: order)
            #expect(result.count == 2)
            let winner = try #require(result.first { $0.language == .english })
            #expect(winner.text.utf8.elementsEqual(composed.text.utf8))
            #expect(winner.lexicalTokenCount == 1 && !winner.isPinyinCorrection)
            #expect(winner.confirmationBoundaries == composed.confirmationBoundaries)
            #expect(result.first?.language == .english)
        }
    }

    @Test func sourceSpansRoundTripThroughUTF8WithoutChangingSessionOffsets() throws {
        let source = "lü'e\u{301}tail"
        let prefix = InputCandidate(text: "绿é", language: .simplifiedChinese, score: -10,
                                    consumedInputCount: 4, lexicalTokenCount: 1)
            .withPresentationScore(0, remembered: false, statisticalScore: -10)
        let literal = InputCandidate(text: source, language: nil, score: 0)
        let rows = RustCandidatePresentation.merge([prefix, literal], input: source,
            languages: [.simplifiedChinese], coverageOrder: true)
        let actual = try #require(rows.first)
        #expect(actual.consumedInputCount == 4 && actual.presentationScore == 5)
        #expect(rows.last == literal)
        #expect(rows.last?.text.utf8.elementsEqual(source.utf8) == true)
        var session = InputSession(engine: CandidateEngine(providers: [PrefixProvider(candidate: prefix)]))
        session.append(source)
        let commit = session.commitResult(actual, reason: .explicitSelection)
        #expect(commit.input.utf8.elementsEqual("lü'e\u{301}".utf8))
        #expect(commit.text == "绿é" && session.buffer == "tail")
    }

    @Test func literalNULAndMixedLanguageFilteringSurviveTheStatelessBridge() {
        let source = "Original\0É"
        let literal = InputCandidate(text: source, language: nil, score: 0)
        let mixed = InputCandidate(text: "你好 hello", language: .simplifiedChinese, score: 100, isMixed: true)
        let ordinary = InputCandidate(text: "hello", language: .english, score: 0)
        for enabled: Set<InputLanguage> in [[], [.english], [.simplifiedChinese]] {
            let result = RustCandidatePresentation.merge([mixed, ordinary, literal], input: source,
                languages: enabled, coverageOrder: false)
            #expect(!result.contains { $0.isMixed })
            #expect(result.last == literal)
            #expect(result.last?.text.utf8.elementsEqual(source.utf8) == true)
        }
        #expect(RustCandidatePresentation.merge([literal], input: "", languages: [], coverageOrder: false).isEmpty)
    }
}

private struct PrefixProvider: CandidateProvider {
    let candidate: InputCandidate
    let language = InputLanguage.simplifiedChinese
    func candidates(for input: String) -> [InputCandidate] { [candidate] }
}
