import CSIRust
import Foundation
import Testing
@testable import SICore

struct RustConversionIntegrationTests {
    @Test func localModelReordersWholeCandidatesIndependentlyOfCorrection() throws {
        let languages = Set(InputLanguage.allCases)
        let spelling = "xianzaitianjiazimu"
        var session = InputSession(engine: CandidateEngine(usesCoverageAdjustedOrder: false), candidateGeneration: .deferred)
        session.configure(languages: languages)
        session.setPrecedingText("视频里面只有声音没有文字所以我想")
        session.append(spelling)
        let baseline = try #require(session.pendingCandidateRequest).generate()
        #expect(baseline.candidates.first?.text == "现在添加字母")

        session.configure(languages: languages, rerankingEnabled: true)
        let request = try #require(session.pendingCandidateRequest)
        let acceptedObsolete = session.accept(baseline)
        #expect(!acceptedObsolete)
        #expect(request.generatePreview().candidates.allSatisfy { $0.rerankingBonus == 0 })
        let ranked = request.generate()
        let promoted = try #require(ranked.candidates.first)
        #expect(promoted.text == "现在添加字幕")
        #expect(promoted.rerankingBonus >= -8 && promoted.rerankingBonus <= 0)
        #expect(Set(ranked.candidates.map(\.id)) == Set(baseline.candidates.map(\.id)))
        let baselineScores = Dictionary(uniqueKeysWithValues: baseline.candidates.map { ($0.id, $0.statisticalScore) })
        #expect(ranked.candidates.allSatisfy { baselineScores[$0.id] == .some($0.statisticalScore) })
        #expect(ranked.candidates.allSatisfy { $0.rerankingBonus >= -8 && $0.rerankingBonus <= 0 })
        #expect(ranked.candidates.filter { $0.rerankingBonus < 0 }.count <= 12)
        for row in ranked.candidates where row.isPartial || row.isLiteral || row.hasCompletion || row.hasLiteralSegments {
            #expect(row.rerankingBonus == 0)
        }
        #expect(ranked.candidates.contains { $0.rerankingBonus < 0 })
        let shortlist = CandidateShortlist.candidates(from: ranked.candidates)
        #expect(shortlist.first?.id == promoted.id)
        #expect(shortlist.contains { $0.text == "现在添加字母" && !$0.isPartial })
        #expect(shortlist.last?.isLiteral == true && shortlist.last?.text == spelling)

        session.configure(languages: languages, pinyinCorrectionMode: .conservative, rerankingEnabled: true)
        let withCorrection = try #require(session.pendingCandidateRequest).generate()
        #expect(withCorrection.candidates.first?.id == promoted.id)
        #expect(withCorrection.candidates.first?.rerankingBonus == promoted.rerankingBonus)
        #expect(withCorrection.candidates.filter(\.isPinyinCorrection).allSatisfy { $0.rerankingBonus == 0 })
        let accepted = session.accept(withCorrection)
        #expect(accepted)
        let commit = session.commitResult(promoted, reason: .defaultAcceptance)
        #expect(commit.text.utf8.elementsEqual("现在添加字幕".utf8))
        #expect(commit.input == spelling && commit.remainingInput.isEmpty)
    }


    @Test func localModelWithNoEffectiveContextAddsBoundedSentenceRewards() throws {
        let engine = try #require(RustConversion.shared)
        let spelling = "xianzaitianjiazimu"
        var presentationEngine = CandidateEngine(usesCoverageAdjustedOrder: false)
        presentationEngine.rerankingEnabled = true
        for context: String? in [nil, "", "上一句话。"] {
            let baseline = engine.candidates(for: spelling, languages: [.simplifiedChinese], precedingText: context)
            let ranked = engine.candidates(for: spelling, languages: [.simplifiedChinese], precedingText: context,
                                           rerankingEnabled: true)
            #expect(Set(ranked.map(\.id)) == Set(baseline.map(\.id)))
            let scores = Dictionary(uniqueKeysWithValues: baseline.map { ($0.id, $0.rankingScore + $0.fieldContextAdjustment) })
            #expect(ranked.allSatisfy { scores[$0.id] == $0.rankingScore + $0.fieldContextAdjustment })
            #expect(ranked.allSatisfy { $0.rerankingBonus >= 0 && $0.rerankingBonus <= 8 })
            #expect(ranked.contains { $0.rerankingBonus > 0 })
            for row in ranked where row.isPartial || row.isLiteral || row.hasCompletion || row.hasLiteralSegments {
                #expect(row.rerankingBonus == 0)
            }
            let presented = presentationEngine.candidates(for: spelling, languages: [.simplifiedChinese], precedingText: context)
            let shortlist = CandidateShortlist.candidates(from: presented)
            #expect(shortlist.first?.id == ranked.first?.id)
            #expect(shortlist.last?.text == spelling && shortlist.last?.isLiteral == true)
        }
    }

    @Test func missingLocalModelFallsBackToStatisticalCandidates() throws {
        let path = try #require(ProcessInfo.processInfo.environment["SI_ENGINE_RESOURCE_DIRECTORY"])
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let absent = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let engine = try #require(RustConversion(lexicon: directory.appending(path: "main.silex"), reranker: absent))
        let spelling = "xianzaitianjiazimu"
        let baseline = engine.candidates(for: spelling, languages: [.simplifiedChinese])
        #expect(!baseline.isEmpty)
        #expect(engine.candidates(for: spelling, languages: [.simplifiedChinese], rerankingEnabled: true) == baseline)
    }

    @Test func pinyinCorrectionChangesDoNotAcceptObsoleteResults() throws {
        _ = try #require(RustConversion.shared)
        var session = InputSession(candidateGeneration: .deferred)
        session.configure(languages: [.simplifiedChinese], pinyinCorrectionMode: .conservative)
        session.append("nihoa")
        let request = try #require(session.pendingCandidateRequest)
        let enabled = request.generate()
        #expect(enabled.candidates.contains { $0.text == "你好" && $0.isPinyinCorrection })
        session.configure(languages: [.simplifiedChinese], pinyinCorrectionMode: .off)
        let acceptedObsolete = session.accept(enabled)
        #expect(!acceptedObsolete)
        let disabled = try #require(session.pendingCandidateRequest).generate()
        let acceptedCurrent = session.accept(disabled)
        #expect(acceptedCurrent)
        #expect(!session.candidates.contains { $0.isPinyinCorrection })
    }

    @Test func nativeCorrectionModeAndByteSpan() throws {
        let path = try #require(ProcessInfo.processInfo.environment["SI_ENGINE_RESOURCE_DIRECTORY"])
        let url = URL(fileURLWithPath: path).appendingPathComponent("main.silex")
        let engine = try #require(url.withUnsafeFileSystemRepresentation { si_engine_open($0, nil) })
        defer { si_engine_close(engine) }

        func correctionForHello() throws -> SICorrectionView? {
            let input = Array("nihoa".utf8)
            let rows = try #require(input.withUnsafeBufferPointer {
                si_engine_candidates(engine, $0.baseAddress, $0.count, nil, 0, 1, true,
                                     nil, 0, nil, 0, nil, 0)
            })
            defer { si_candidates_free(rows) }
            for index in 0..<si_candidates_count(rows) {
                var row = SICandidateView()
                var correction = SICorrectionView()
                guard si_candidates_get(rows, index, &row),
                      si_candidates_get_correction(rows, index, &correction) else { continue }
                let text = String(decoding: UnsafeBufferPointer(start: row.text, count: row.text_bytes), as: UTF8.self)
                if text == "你好" {
                    #expect(row.confirmation_boundary_count == 0)
                    return correction
                }
            }
            return nil
        }

        #expect(try correctionForHello() == nil)
        for mode: UInt8 in [1, 2] {
            try #require(si_engine_set_correction(engine, mode))
            let view = try #require(try correctionForHello())
            #expect(view.kind == 4)
            #expect(view.word_start_bytes == 0)
            #expect(view.word_end_bytes == 5)
        }
        #expect(!si_engine_set_correction(engine, 255))
        #expect(try correctionForHello() != nil)
        try #require(si_engine_set_correction(engine, 0))
        #expect(try correctionForHello() == nil)
    }

    @Test func swiftCorrectionCandidateCannotTrainOrAutomaticallyConfirm() throws {
        let path = try #require(ProcessInfo.processInfo.environment["SI_ENGINE_RESOURCE_DIRECTORY"])
        let url = URL(fileURLWithPath: path).appendingPathComponent("main.silex")
        let engine = try #require(RustConversion(lexicon: url, correctionMode: .conservative))
        let candidates = engine.candidates(for: "nihoa", languages: [.simplifiedChinese], includesConfirmation: true)
        let correction = try #require(candidates.first { $0.text == "你好" && $0.isPinyinCorrection })
        #expect(!correction.canLearn)
        #expect(!correction.isPartial)
        #expect(correction.confirmationBoundaries.isEmpty)
    }

    @Test func precedingTextReachesBothSearchesWithoutBecomingALearnedScore() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SentenceLearningStore(profile: directory.appending(path: "model.si-user"))
        let learned = try await store.ingest(Array(repeating: "want books", count: 20), batchID: UUID())
        let model = try #require(learned.model)
        var session = InputSession(candidateGeneration: .deferred)
        session.configure(languages: [.english], applicationMemory: ApplicationMemorySnapshot(sentenceModel: model))
        session.setPrecedingText("First sentence. want ")
        session.append("books")
        let contextual = try #require(session.pendingCandidateRequest)
        let contextualCandidate = try #require(contextual.generate().candidates.first { $0.text == "books" && !$0.isLiteral })
        let previewCandidate = try #require(contextual.generatePreview().candidates.first { $0.text == "books" && !$0.isLiteral })
        #expect(contextualCandidate.fieldContextAdjustment > 0)
        #expect(previewCandidate.fieldContextAdjustment == contextualCandidate.fieldContextAdjustment)

        session.setPrecedingText(nil)
        let acceptedObsoleteResult = session.accept(contextual.generate())
        #expect(!acceptedObsoleteResult)
        let baseline = try #require(session.pendingCandidateRequest)
        let baselineCandidate = try #require(baseline.generate().candidates.first { $0.text == "books" && !$0.isLiteral })
        #expect(baselineCandidate.rankingScore == contextualCandidate.rankingScore)
        #expect(baselineCandidate.fieldContextAdjustment == 0)
        #expect((contextualCandidate.presentationScore ?? 0) > (baselineCandidate.presentationScore ?? 0))
        session.setPrecedingText("")
        let confirmedStart = try #require(session.pendingCandidateRequest)
        session.setPrecedingText(nil)
        let acceptedKnownStart = session.accept(confirmedStart.generate())
        #expect(!acceptedKnownStart)
    }

    @Test func precedingCacheFollowsSessionEditsResourceUpdatesAndReset() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SentenceLearningStore(profile: directory.appending(path: "model.si-user"))
        let learned = try await store.ingest(Array(repeating: "want books", count: 20), batchID: UUID())
        let model = try #require(learned.model)
        var memory = ApplicationMemorySnapshot(sentenceModel: model)
        var session = InputSession(candidateGeneration: .deferred)
        session.configure(languages: [.english], applicationMemory: memory)
        session.setPrecedingText("want ")
        let engine = CandidateEngine()
        for letter in ["b", "o", "o", "k", "s"] {
            session.append(letter)
            let request = try #require(session.pendingCandidateRequest)
            let expected = engine.candidates(for: session.buffer, languages: [.english], applicationMemory: memory,
                                             precedingText: "want ")
            #expect(request.generate().candidates == expected)
        }
        let obsolete = try #require(session.pendingCandidateRequest)
        let updated = try await store.ingest(Array(repeating: "read books", count: 20), batchID: UUID())
        let updatedModel = try #require(updated.model)
        memory = ApplicationMemorySnapshot(sentenceModel: updatedModel)
        session.configure(languages: [.english], applicationMemory: memory)
        let current = try #require(session.pendingCandidateRequest)
        #expect(current.generate().candidates == engine.candidates(for: "books", languages: [.english],
            applicationMemory: memory, precedingText: "want "))
        let acceptedOld = session.accept(obsolete.generate())
        #expect(!acceptedOld)
        session.reset()
        session.setPrecedingText(nil)
        session.append("books")
        let fresh = try #require(session.pendingCandidateRequest)
        #expect(fresh.generate().candidates == engine.candidates(for: "books", languages: [.english], applicationMemory: memory))
        let acceptedBeforeReset = session.accept(current.generate())
        #expect(!acceptedBeforeReset)
    }

    @Test func sharedEngineReturnsBothLanguagesAndLiteral() throws {
        _ = try #require(RustConversion.shared)
        let engine = CandidateEngine()
        let both = engine.candidates(for: "he", languages: [.english, .simplifiedChinese])
        #expect(both.contains { $0.text == "he" && $0.language == .english && !$0.hasCompletion })
        #expect(both.contains { $0.text == "和" && $0.language == .simplifiedChinese })
        #expect(both.last?.isLiteral == true && both.last?.text == "he")
        let disabled = engine.candidates(for: "Exact_🦉", languages: [])
        #expect(disabled.count == 1 && disabled[0].isLiteral && disabled[0].text == "Exact_🦉")
    }

    @Test func prefixBridgeConsumesOriginalUmlautAndSeparator() throws {
        var session = InputSession()
        session.configure(languages: [.simplifiedChinese])
        session.append("lu:'se")
        let prefix = try #require(session.candidates.first {
            $0.text == "绿" && $0.consumedInputCount == 4
        })
        let commit = session.commitResult(prefix, reason: .explicitSelection)
        #expect(commit.input == "lu:'")
        #expect(commit.text == "绿")
        #expect(session.buffer == "se")
    }

    @Test func personalPhrasesJoinRustPathsAndAreIneligibleForLearning() throws {
        let phrase = try UserPhrase(input: "qxz", text: "小鹿", language: .simplifiedChinese, isPinned: true)
        let dictionary = try UserDictionary(entries: [phrase])
        let engine = CandidateEngine()
        let exact = engine.candidates(for: "qxz", languages: [.simplifiedChinese], dictionary: dictionary)
        #expect(exact.first?.text == "小鹿" && exact.first?.isPreferred == true)
        let sentence = engine.candidates(for: "nihaoqxz", languages: [.simplifiedChinese], dictionary: dictionary,
                                         includesConfirmationEvidence: true)
        let composed = try #require(sentence.first { $0.text == "你好小鹿" && !$0.isPartial })
        #expect(composed.isUserPhrase && !composed.canLearn && composed.confirmationBoundaries.isEmpty)
    }

    @Test func exactChineseAlignmentIsAvailableOnlyWhenRequested() throws {
        let engine = CandidateEngine()
        let input = "ni'hao"
        let normal = try #require(engine.candidates(for: input, languages: [.simplifiedChinese]).first { $0.text == "你好" })
        #expect(normal.confirmationBoundaries.isEmpty)
        let traced = try #require(engine.candidates(for: input, languages: [.simplifiedChinese],
                                                  includesConfirmationEvidence: true).first { $0.text == "你好" })
        #expect(traced.sourceSegmentBoundaries == [3, 6])
        #expect(traced.confirmationBoundaries.contains(ConfirmationBoundary(sourceCount: 3, outputByteCount: 3)))
    }

    @Test func abbreviationAndEnglishSeparatorKeepExactRemainders() throws {
        var session = InputSession()
        session.configure(languages: [.simplifiedChinese])
        session.append("jintjiushi")
        let today = try #require(session.candidates.first { $0.text == "今天" && $0.consumedInputCount == 4 })
        #expect(session.commitResult(today, reason: .explicitSelection).input == "jint")
        #expect(session.buffer == "jiushi")
        session.reset()
        session.configure(languages: [.english])
        session.append("i'want'to'build")
        #expect(session.candidates.contains { $0.text == "I want to build" && !$0.isPartial })
        #expect(session.candidates.last?.text == "i'want'to'build")
    }

    @Test func standaloneWordPreferenceCanRankAConstructedRustPath() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let profile = LearningProfile(entries: [LearnedPreference(
            input: "shike", text: "食客", language: .simplifiedChinese, strength: 8, lastUsed: now
        )], now: now)
        let engine = CandidateEngine()
        let base = engine.candidates(for: "woshike", languages: [.simplifiedChinese], now: now)
        let ranked = engine.candidates(for: "woshike", languages: [.simplifiedChinese], learning: profile, now: now)
        let learned = try #require(ranked.first { $0.text == "我食客" && !$0.isPartial })
        #expect(learned.tokenLearningBonus > 0)
        #expect(ranked.first?.id == learned.id)
        #expect(base.first?.id != learned.id)
    }

    @Test func englishPersonalPhraseRetainsExplicitCodeAndOutput() throws {
        let phrase = try UserPhrase(input: "q'z", text: "Custom  Spacing", language: .english, isPinned: true)
        let dictionary = try UserDictionary(entries: [phrase])
        let engine = CandidateEngine()
        let exact = engine.candidates(for: "Q'Z", languages: [.english], dictionary: dictionary)
        #expect(exact.first?.text == phrase.text && exact.first?.isPreferred == true)
        #expect(!engine.candidates(for: "qz", languages: [.english], dictionary: dictionary).contains { $0.isUserPhrase })
        let joined = engine.candidates(for: "nihaoq'z", languages: Set(InputLanguage.allCases), dictionary: dictionary)
        #expect(joined.contains { $0.text == "你好Custom  Spacing" && $0.isMixed && !$0.canLearn })
    }

    @Test func aDisplayedPreviewPrefixCanBeConfirmedBeforeFinalSearch() throws {
        var session = InputSession(candidateGeneration: .deferred)
        session.configure(languages: [.simplifiedChinese])
        session.append("lu:'se")
        let request = try #require(session.pendingCandidateRequest)
        let acceptedPreview = session.accept(request.generatePreview())
        #expect(acceptedPreview)
        let prefix = try #require(session.candidates.first { $0.text == "绿" && $0.consumedInputCount == 4 })
        let commit = session.commitResult(prefix, reason: .explicitSelection)
        #expect(commit.text == "绿" && commit.input == "lu:'" && session.buffer == "se")
        let acceptedStaleResult = session.accept(request.generate())
        #expect(!acceptedStaleResult)
    }
}

private struct TypoSuggestionProvider: CandidateProvider {
    let language: InputLanguage = .simplifiedChinese

    func candidates(for input: String) -> [InputCandidate] {
        guard input == "nihoa" else { return [] }
        return [InputCandidate(text: "你好", language: language, score: 100, isPinyinCorrection: true)]
    }
}

extension RustConversionIntegrationTests {
    @Test func correctionRequiresExplicitSelectionInSession() throws {
        let engine = CandidateEngine(providers: [TypoSuggestionProvider()], punctuationCandidatesEnabled: true)
        var session = InputSession(engine: engine)
        for reason: CommitReason in [.defaultAcceptance, .passthrough, .explicitSelection] {
            session.append("nihoa")
            let suggestion = try #require(session.candidates.first { $0.isPinyinCorrection })
            let commit = session.commitResult(suggestion, reason: reason)
            #expect(commit.input == "nihoa")
            #expect(commit.text == (reason == .explicitSelection ? "你好" : "nihoa"))
            #expect(!commit.canLearn)
        }
        session.append("nihoa.")
        #expect(!session.candidates.contains { $0.text == "你好。" })
    }
}
