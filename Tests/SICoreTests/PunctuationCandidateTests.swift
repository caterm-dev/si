import Testing
@testable import SICore

struct PunctuationCandidateTests {
    private let languages = Set(InputLanguage.allCases)

    @Test func punctuationCandidatesAreDisabledByDefaultInFullAndPreviewSearches() {
        let engine = CandidateEngine(providers: [PunctuationWordFixture()])
        #expect(!engine.punctuationCandidatesEnabled)
        for input in [",", ".", "/", ";", "'", "nihao,"] {
            let full = engine.candidates(for: input, languages: languages)
            let preview = engine.previewCandidates(for: input, languages: languages, learning: LearningProfile(),
                                                   dictionary: UserDictionary(), now: .now, context: nil)
            #expect(full.count == 1 && full.first?.text == input && full.first?.isLiteral == true)
            #expect(full.allSatisfy { !$0.isPunctuation && $0.punctuationLanguage == nil })
            #expect(preview == full)
            #expect(full.first?.appendsSpaceOnAcceptance == true)
        }
    }

    @Test func togglingPunctuationRejectsPendingResultsAndSelectionsWithoutLosingSpelling() throws {
        var session = InputSession(engine: CandidateEngine(providers: []), candidateGeneration: .deferred)
        session.append(",")
        let disabled = try #require(session.pendingCandidateRequest)
        session.configure(languages: languages, punctuationCandidatesEnabled: true)
        let enabled = try #require(session.pendingCandidateRequest)
        let acceptedDisabled = session.accept(disabled.generate())
        #expect(!acceptedDisabled && session.buffer == ",")
        let acceptedEnabled = session.accept(enabled.generatePreview())
        #expect(acceptedEnabled && session.candidates.contains { $0.text == "，" })
        let oldChoice = try #require(session.candidates.first { $0.text == "，" })
        session.configure(languages: languages, punctuationCandidatesEnabled: false)
        #expect(session.buffer == "," && session.cursorUTF16Offset == 1)
        #expect(session.candidates.count == 1 && session.candidates.first?.isPunctuation == false)
        let acceptedOldPreview = session.accept(enabled.generatePreview())
        let acceptedOldFull = session.accept(enabled.generate())
        #expect(!acceptedOldPreview && !acceptedOldFull)
        session.resolveCandidates()
        #expect(session.candidates.count == 1 && session.candidates.first?.isLiteral == true)
        #expect(session.commit(oldChoice) == ",")
    }

    @Test func standalonePunctuationKeepsLanguagesAndExactOriginal() throws {
        let engine = CandidateEngine(providers: [], punctuationCandidatesEnabled: true)
        for (input, chinese) in [(",", ["，", "、"]), (".", ["。", "…"]), ("/", ["、"]),
                                 (";", ["；"]), ("'", ["‘", "’"]), ("\"", ["“", "”"])] {
            let result = engine.candidates(for: input, languages: languages)
            #expect(result.first?.text == input && result.first?.punctuationLanguage == .english)
            #expect(result.filter { $0.punctuationLanguage == .simplifiedChinese }.map(\.text) == chinese)
            #expect(result.last?.text == input && result.last?.isLiteral == true)
            #expect(Set(result.map(\.id)).count == result.count)
            #expect(result == engine.candidates(for: input, languages: languages))
            for candidate in result {
                #expect(!candidate.appendsSpaceOnAcceptance)
                #expect(!candidate.canLearn)
                #expect(CandidateContext(candidate: candidate) == nil)
            }
            let english = try #require(result.first)
            #expect(english.label == "English Punctuation")
            #expect(result[1].label == "Chinese Punctuation")
        }
    }

    @Test func disabledLanguagesNeverSupplyPunctuation() {
        let engine = CandidateEngine(providers: [], punctuationCandidatesEnabled: true)
        for enabled: Set<InputLanguage> in [[], [.english], [.simplifiedChinese], languages] {
            let result = engine.candidates(for: ",", languages: enabled)
            #expect(result.filter { !$0.isLiteral }.allSatisfy {
                $0.punctuationLanguage.map(enabled.contains) == true && $0.language.map(enabled.contains) == true
            })
            #expect(result.last?.text == "," && result.last?.isLiteral == true)
            if enabled.isEmpty { #expect(result.count == 1) }
        }
    }

    @Test func completeWordsGainPunctuationWithoutConfirmingIncompleteOrPrefixChoices() {
        let engine = CandidateEngine(providers: [PunctuationWordFixture()], punctuationCandidatesEnabled: true)
        let result = engine.candidates(for: "nihao,", languages: languages)
        #expect(result.map(\.text) == ["你好,", "你好，", "你好、", "nihao,"])
        #expect(result.dropLast().allSatisfy { !$0.isPartial && !$0.canLearn && !$0.appendsSpaceOnAcceptance })
        #expect(result[0].language == .simplifiedChinese && result[0].punctuationLanguage == .english)
        #expect(result[1].language == .simplifiedChinese && result[1].punctuationLanguage == .simplifiedChinese)
        #expect(result[0].id != result[1].id)
    }

    @Test func apostrophesInsidePinyinStaySeparators() {
        let engine = CandidateEngine(providers: [PunctuationWordFixture()], punctuationCandidatesEnabled: true)
        for input in ["ni'", "ni'hao", "ni'hao'"] {
            let result = engine.candidates(for: input, languages: languages)
            #expect(result.allSatisfy { $0.punctuationLanguage == nil })
            #expect(result.last?.text == input)
        }
        #expect(engine.candidates(for: "ni'hao.", languages: languages).contains { $0.text == "你好。" })
    }

    @Test func domainsCodeAndRepeatedSymbolsKeepOriginalWithoutRecursiveExpansion() {
        let engine = CandidateEngine(providers: [PunctuationWordFixture()], punctuationCandidatesEnabled: true)
        for input in ["example.com", "user@example.com", "foo/bar", "MyTool/", "nihao,world", String(repeating: ".", count: 5_000)] {
            let result = engine.candidates(for: input, languages: languages)
            #expect(result.count == 1 && result.first?.isLiteral == true && result.first?.text == input)
        }
        #expect(engine.candidates(for: "", languages: languages).isEmpty)
    }

    @Test func punctuationCannotTrainAndPersonalVerbatimPathsStillInvalidateHistory() throws {
        let personal = InputCandidate(text: "Synthetic Phrase", language: .english, score: 100, isUserPhrase: true)
        let verbatim = InputCandidate(text: "中文synthetic", language: .simplifiedChinese, score: 90,
                                     isMixed: true, hasLiteralSegments: true)
        for prefix in [personal, verbatim] {
            let candidates = PunctuationCandidates.candidates(symbol: ",", prefixes: [prefix], languages: languages)
            let candidate = try #require(candidates.first)
            #expect(candidate.isUserPhrase == prefix.isUserPhrase)
            #expect(candidate.hasLiteralSegments == prefix.hasLiteralSegments)
            let commit = InputCommit(input: "synthetic,", candidate: candidate, reason: .explicitSelection)
            var profile = LearningProfile()
            let learned = profile.record(commit, learnContext: true)
            #expect(!learned)
            var history = InputHistoryDraft()
            history.append(commit)
            #expect(history.isInvalid)
        }
        let oversized = InputCandidate(text: String(repeating: "x", count: 4_096), language: .english, score: 100)
        #expect(PunctuationCandidates.candidates(symbol: ",", prefixes: [oversized], languages: languages).isEmpty)
    }

    @Test func sessionSelectionEditingAndStaleDeliveryPreservePunctuation() throws {
        var session = InputSession(engine: CandidateEngine(providers: [], punctuationCandidatesEnabled: true), candidateGeneration: .deferred)
        session.append(",")
        let stale = try #require(session.pendingCandidateRequest)
        session.deleteBackward()
        session.append(".")
        let acceptedStale = session.accept(stale.generate())
        #expect(!acceptedStale)
        let request = try #require(session.pendingCandidateRequest)
        let acceptedPreview = session.accept(request.generatePreview())
        #expect(acceptedPreview)
        let preview = session.candidates
        let acceptedFull = session.accept(request.generate())
        #expect(acceptedFull)
        #expect(session.candidates == preview)
        let chinese = try #require(session.candidates.first { $0.text == "。" })
        let commit = session.commitResult(chinese, reason: .explicitSelection)
        #expect(commit.text == "。" && commit.remainingInput.isEmpty && session.buffer.isEmpty)
        #expect(!commit.text.contains("Chinese"))
        let acceptedAfterCommit = session.accept(request.generate())
        #expect(!acceptedAfterCommit)
        session.append("'")
        #expect(session.commit() == "'")
        session.append(";")
        session.reset()
        #expect(session.candidates.isEmpty)
    }

    @Test func productionPreviewAndFullSearchExposeBothPunctuationLanguages() throws {
        let engine = CandidateEngine(punctuationCandidatesEnabled: true)
        let full = engine.candidates(for: "nihao.", languages: languages)
        #expect(full.contains { $0.text == "你好." && $0.punctuationLanguage == .english })
        #expect(full.contains { $0.text == "你好。" && $0.punctuationLanguage == .simplifiedChinese })
        #expect(full.last?.text == "nihao." && full.last?.isLiteral == true)
        let preview = engine.previewCandidates(for: "nihao.", languages: languages, learning: LearningProfile(),
                                               dictionary: UserDictionary(), now: .now, context: nil)
        #expect(preview.contains { $0.text == "你好。" && $0.punctuationLanguage == .simplifiedChinese })
        #expect(preview.last?.text == "nihao.")
        #expect(full.allSatisfy { $0.confirmationBoundaries.isEmpty })
    }
}

private struct PunctuationWordFixture: CandidateProvider {
    let language = InputLanguage.simplifiedChinese

    func candidates(for input: String) -> [InputCandidate] {
        guard ["nihao", "ni'hao"].contains(input) else { return [] }
        return [InputCandidate(text: "你好", language: language, score: 100),
                InputCandidate(text: "你", language: language, score: 90, consumedInputCount: 2),
                InputCandidate(text: "你好世界", language: language, score: 80, hasCompletion: true)]
    }
}
