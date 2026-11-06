import Foundation
import Testing
@testable import SICore

struct KenLMRankingTests {
    @Test func explicitResolutionUsesCurrentDictionaryRankingWhileModelWorkIsPending() throws {
        guard let path = ProcessInfo.processInfo.environment["SI_TEST_KENLM_INSTALLATION"] else { return }
        let model = try #require(KenLMModel.openInstalled(at: URL(fileURLWithPath: path)))
        var ranking = RankingExperiment(model: model, languageModelWeight: 0.25, wordInsertionBits: 28.85,
                                       englishWordInsertionBits: 28, fullCoverageFirst: true)
        let now = Date(timeIntervalSince1970: 0)
        var session = InputSession(engine: CandidateEngine(rankingExperiment: ranking), candidateGeneration: .deferred)
        session.append("nihaopengyou", now: now)
        let request = try #require(session.pendingCandidateRequest)
        let workerResult = request.generate()
        #expect(workerResult.candidates.contains { $0.lmOOVRatio != nil })
        #expect(request.generatePreview().candidates.allSatisfy { $0.lmOOVRatio == nil })
        ranking.model = nil
        let fallback = CandidateEngine(rankingExperiment: ranking)
        session.resolveCandidates()
        #expect(session.candidates == fallback.candidates(for: session.buffer, languages: Set(InputLanguage.allCases), now: now))
        let accepted = session.accept(workerResult, now: now)
        #expect(!accepted)
    }

    @Test func zeroWeightPreservesCandidatesWindowAndCommits() throws {
        let path = ProcessInfo.processInfo.environment["SI_TEST_KENLM_INSTALLATION"]
        let model = path.flatMap { KenLMModel.openInstalled(at: URL(fileURLWithPath: $0)) }
        if path != nil { _ = try #require(model) }
        let now = Date(timeIntervalSince1970: 0)
        for input in ["goon", "nihaopengyou", "wo'xiang", "woxiangyaodeploy", "GOON", "example.com"] {
            var legacy = InputSession(candidateGeneration: .deferred)
            var zero = InputSession(engine: CandidateEngine(rankingExperiment: RankingExperiment(
                model: model, languageModelWeight: 0, englishLanguageModelWeight: 0,
                frequencyWeight: 2, wordInsertionBits: -4)), candidateGeneration: .deferred)
            legacy.append(input, now: now)
            zero.append(input, now: now)
            let legacyRequest = try #require(legacy.pendingCandidateRequest)
            let zeroRequest = try #require(zero.pendingCandidateRequest)
            #expect(legacyRequest.generatePreview().candidates == zeroRequest.generatePreview().candidates)
            let left = legacyRequest.generate()
            let right = zeroRequest.generate()
            #expect(left.candidates == right.candidates)
            let leftWindow = CandidateShortlist.candidates(from: left.candidates)
            let rightWindow = CandidateShortlist.candidates(from: right.candidates)
            #expect(leftWindow == rightWindow)
            let legacyAccepted = legacy.accept(left)
            let zeroAccepted = zero.accept(right)
            #expect(legacyAccepted && zeroAccepted)
            for (first, second) in zip(leftWindow, rightWindow) {
                var a = legacy
                var b = zero
                let outA = a.commitResult(first, reason: .explicitSelection, now: now)
                let outB = b.commitResult(second, reason: .explicitSelection, now: now)
                #expect(outA.text.utf8.elementsEqual(outB.text.utf8))
                #expect(a.buffer.utf8.elementsEqual(b.buffer.utf8))
            }
        }
    }

    @Test func installedModelScoresOnlyChineseAtDefaultEnglishWeight() throws {
        guard let path = ProcessInfo.processInfo.environment["SI_TEST_KENLM_INSTALLATION"] else { return }
        let model = try #require(KenLMModel.openInstalled(at: URL(fileURLWithPath: path)))
        let experimental = CandidateEngine(rankingExperiment: RankingExperiment(model: model, languageModelWeight: 0.5))
        let legacy = CandidateEngine()
        #expect(experimental.candidates(for: "goon", languages: [.english])
            == legacy.candidates(for: "goon", languages: [.english]))
        let chinese = experimental.candidates(for: "nihaopengyou", languages: [.simplifiedChinese])
        #expect(chinese.contains { $0.lmOOVRatio != nil })
    }
}

extension KenLMRankingTests {
    @Test func coverageExperimentSeparatesWholeAndPrefixActions() throws {
        let engine = CandidateEngine(rankingExperiment: RankingExperiment(fullCoverageFirst: true))
        var session = InputSession(engine: engine)
        session.configure(languages: [.english])
        session.append("goon")
        let values = session.candidates
        let prefix = try #require(values.first { $0.text == "go" && $0.consumedInputCount == 2 })
        let whole = try #require(values.first { $0.text == "go on" && !$0.isPartial })
        #expect(values.firstIndex(of: whole)! < values.firstIndex(of: prefix)!)
        let tailsArePartial = values.filter { !$0.isLiteral }.drop(while: { !$0.isPartial }).allSatisfy(\.isPartial)
        #expect(tailsArePartial)
        #expect(CandidateShortlist.candidates(from: values).contains(prefix))
        let result = session.commitResult(prefix, reason: .explicitSelection)
        #expect(result.text == "go")
        #expect(result.remainingInput == "on")
    }
}

extension KenLMRankingTests {
    @Test func featuresFollowWinningLexicalEdgesAndCoverageGroups() throws {
        let candidates = CandidateEngine().candidates(for: "goon", languages: [.english])
        let features = CandidateRankingPool(candidates: candidates, model: nil).features(input: "goon")
        let prefix = try #require(features.first { $0.identity == "prefix2:en:go" })
        let whole = try #require(features.first { $0.identity == "en:go on" })
        let literal = try #require(features.first { $0.identity == "literal:goon" })
        #expect(prefix.values["coverage"] == 0.5)
        #expect(prefix.values["is_full_match"] == 0)
        #expect(prefix.relative["coverage"]?.deltaFromBest == 0)
        #expect(whole.values["num_words"] == 2)
        #expect(whole.values["avg_word_len"] == 2)
        #expect(whole.values["input_is_dictionary_word"] == 1)
        #expect(abs((whole.values["log_freq_sum"] ?? 0) - 36.9015719) < 0.000001)
        #expect(literal.values["num_words"] == nil)
    }

    @Test func offlinePoolAndAppEngineShareModelFeaturesAndOrder() throws {
        guard let path = ProcessInfo.processInfo.environment["SI_TEST_KENLM_INSTALLATION"] else { return }
        let model = try #require(KenLMModel.openInstalled(at: URL(fileURLWithPath: path)))
        let configuration = RankingExperiment(model: model, languageModelWeight: 0.5, fullCoverageFirst: true)
        let input = "woxiangyaodeploy"
        let languages = Set(InputLanguage.allCases)
        let baseline = CandidateEngine().candidates(for: input, languages: languages)
        let pool = CandidateRankingPool(candidates: baseline, model: model)
        let app = CandidateEngine(rankingExperiment: configuration).candidates(for: input, languages: languages)
        #expect(pool.ranked(using: configuration) == app)
        let features = Dictionary(uniqueKeysWithValues: pool.features(input: input).map { ($0.identity, $0.values) })
        for candidate in app { #expect(candidate.lmOOVRatio == features[candidate.id]?["lm_oov_ratio"]) }
    }
}

extension KenLMRankingTests {
    @Test func tuningFirstUsesSameOrderAsFrozenEvaluation() throws {
        guard let path = ProcessInfo.processInfo.environment["SI_TEST_KENLM_INSTALLATION"] else { return }
        let model = try #require(KenLMModel.openInstalled(at: URL(fileURLWithPath: path)))
        let candidates = CandidateEngine().candidates(for: "nihaopengyou", languages: [.simplifiedChinese])
        let pool = CandidateRankingPool(candidates: candidates, model: model, context: ["朋友"])
        for coverage in [false, true] {
            for wip in [-4.0, 0, 16, 28.85] {
                let profile = RankingExperiment(model: model, languageModelWeight: 0.25,
                                                wordInsertionBits: wip, fullCoverageFirst: coverage)
                #expect(pool.first(using: profile)?.id == pool.ranked(using: profile).first?.id)
                #expect(pool.first(using: profile, insertionOnly: true)?.id
                    == pool.ranked(using: profile, insertionOnly: true).first?.id)
            }
        }
    }
}

extension KenLMRankingTests {
    @Test func englishInsertionAdjustmentCountsOnlyEnglishDictionaryTokens() throws {
        let base = CandidateEngine()
        let penalty = RankingExperiment.defaultEnglishWordInsertionBits
        let adjusted = CandidateEngine(rankingExperiment: RankingExperiment(englishWordInsertionBits: penalty + 4))
        let now = Date(timeIntervalSince1970: 0)
        let languages = Set(InputLanguage.allCases)
        for (input, text, delta) in [("cannot", "cannot", 4.0), ("cannot", "can not", 8.0),
                                     ("woxiangyaodeploy", "我想要 deploy", 4.0),
                                     ("nihao", "你好", 0.0)] {
            let before = try #require(base.candidates(for: input, languages: languages, now: now)
                .first { $0.text == text && !$0.isPartial && !$0.isLiteral })
            let after = try #require(adjusted.candidates(for: input, languages: languages, now: now)
                .first { $0.id == before.id })
            let previous = try #require(before.presentationScore)
            let current = try #require(after.presentationScore)
            #expect(abs(previous - current - delta) < 1e-10)
        }
        #expect(adjusted.candidates(for: "nihao", languages: [.simplifiedChinese], now: now)
            == base.candidates(for: "nihao", languages: [.simplifiedChinese], now: now))
    }

    @Test func goldProbeSeparatesLatticeReachabilityFromLexicalRowAndInputLimits() {
        let alternatives = (0..<32).map { index in
            PinyinLexiconEntry(syllables: ["ni"], text: "替\(index)", score: 100)
        }
        let decoder = PinyinDecoder(entries: alternatives + [
            PinyinLexiconEntry(syllables: ["ni"], text: "你", score: 50),
            PinyinLexiconEntry(syllables: ["hao"], text: "好"),
        ])
        #expect(decoder.probeGoldLattice(for: "nihao", gold: "替0好") == .inBoundedLattice)
        #expect(decoder.probeGoldLattice(for: "nihao", gold: "你好") == .lexicalRowLimit)
        #expect(decoder.probeGoldLattice(for: "nihao", gold: "你号") == .noPath)
        #expect(decoder.probeGoldLattice(for: String(repeating: "ni", count: 33), gold: "你") == .inputLimit)
    }

    @Test func coveragePreservesEnglishScoresAndWholeCommitBoundaries() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try String(contentsOf: repo.appendingPathComponent("eval/ranking/hard-cases.tsv"), encoding: .utf8)
        let legacy = CandidateEngine()
        let engine = CandidateEngine(rankingExperiment: RankingExperiment(fullCoverageFirst: true))
        let knownMismatches = ["goon": "goon", "cannot": "can not"]
        for row in fixture.split(separator: "\n") {
            let fields = row.split(separator: "\t", omittingEmptySubsequences: false)
            try #require(fields.count == 2 && !fields[0].isEmpty)
            let input = String(fields[0]), expected = String(fields[1])
            if expected.isEmpty { continue }
            for languages: Set<InputLanguage> in [[.english], [.english, .simplifiedChinese]] {
                var session = InputSession(engine: engine)
                session.configure(languages: languages)
                session.append(input)
                let scores = Dictionary(uniqueKeysWithValues: legacy.candidates(for: input, languages: languages)
                    .filter { $0.language == .english }.map { ($0.id, $0.presentationScore) })
                let coveredScores = Dictionary(uniqueKeysWithValues: session.candidates
                    .filter { $0.language == .english }.map { ($0.id, $0.presentationScore) })
                #expect(coveredScores == scores, Comment(rawValue: input))
                let window = CandidateShortlist.candidates(from: session.candidates)
                let first = try #require(window.first)
                #expect(first.text == (knownMismatches[input] ?? expected), Comment(rawValue: input))
                #expect(!first.isPartial && !first.isLiteral)
                let target = try #require(window.first { $0.text == expected && !$0.isPartial && !$0.isLiteral })
                let commit = session.commitResult(target, reason: .explicitSelection)
                #expect(commit.text == expected && commit.remainingInput.isEmpty)
            }
        }
    }
}
