import Foundation
import Testing
@testable import SICore
@testable import SIPresentation

@MainActor
struct CandidatePipelineTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SI_TEST_ENGINE_RESOURCE_DIRECTORY"] != nil))
    func appRankingUsesTheSameStatisticalOrderInTheWorkerAndSynchronously() async throws {
        let gate = Gate()
        var final: CandidateResult?
        let pipeline = CandidatePipeline {
            final = $0
            gate.didReceive()
        }
        var session = InputSession(candidateGeneration: .deferred)
        session.configure(languages: [.simplifiedChinese, .english],
                          experimentalRankingEnabled: true, rankingPolicy: .app)
        session.append("xiandingge")
        let request = try #require(session.pendingCandidateRequest)
        #expect(!request.offersPreview)
        let synchronous = request.generate()
        pipeline.submit(request)
        await gate.waitForReceipts(1)
        let background = try #require(final)
        #expect(background.candidates == synchronous.candidates)
        #expect(!background.isModelRanked)
        var selection = CandidateSelection()
        selection.update(background.candidates)
        #expect(selection.candidates.first?.text == "先定个")

        session.configure(languages: [.simplifiedChinese, .english], pinyinCorrectionMode: .conservative,
                          experimentalRankingEnabled: true, rankingPolicy: .app)
        let correction = try #require(session.pendingCandidateRequest)
        #expect(correction.offersPreview)
        let stale = session.accept(background)
        #expect(!stale)
        let corrected = correction.generate(useExperimentalRanking: true)
        #expect(corrected.isModelRanked)
        selection.update(corrected.candidates)
        #expect(selection.candidates.first?.text == "先定个")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SI_TEST_CALIBRATED_CORRECTION"] == "1"))
    func calibratedCorrectionReachesTheFrontPageAndRequiresExplicitAcceptance() throws {
        for (input, target) in [("nihoa", "你好"), ("houmo", "周末")] {
            var session = InputSession(candidateGeneration: .deferred)
            session.configure(languages: [.simplifiedChinese, .english],
                              pinyinCorrectionMode: .conservative, experimentalRankingEnabled: true)
            session.append(input)
            let request = try #require(session.pendingCandidateRequest)
            if input == "houmo" {
                #expect(!request.generate().candidates.contains { $0.isPinyinCorrection && $0.text == target })
            }
            let ranked = request.generate(useExperimentalRanking: true)
            let accepted = session.accept(ranked)
            #expect(accepted)
            let suggestion = try #require(session.candidates.first { $0.isPinyinCorrection && $0.text == target })
            #expect(suggestion.modelRankingScore != nil && !suggestion.canLearn)
            var selection = CandidateSelection()
            selection.update(session.candidates)
            let number = try #require((1...selection.visiblePageSize).first { selection.candidate(number: $0)?.id == suggestion.id })
            #expect(selection.confirmationReason(for: selection.candidate(number: number)) == .explicitSelection)
            var implicit = session
            #expect(implicit.commitResult(suggestion, reason: .defaultAcceptance).text == input)
            let commit = session.commitResult(suggestion, reason: .explicitSelection)
            #expect(commit.text == target && commit.input == input && commit.remainingInput.isEmpty)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SI_TEST_ENGINE_RESOURCE_DIRECTORY"] != nil))
    func experimentalModelsReachWorkerShortlistAndExplicitCommit() async throws {
        let gate = Gate()
        var result: CandidateResult?
        let pipeline = CandidatePipeline {
            result = $0
            gate.didReceive()
        }
        var session = InputSession(candidateGeneration: .deferred)
        session.configure(languages: [.simplifiedChinese, .english], experimentalRankingEnabled: true)
        session.setPrecedingText("先定个")
        session.append("fangan")
        let request = try #require(session.pendingCandidateRequest)
        let baseline = request.generate()
        #expect(!baseline.isModelRanked)
        #expect(!request.generatePreview().isModelRanked)
        pipeline.submit(request)
        await gate.waitForReceipts(1)
        let ranked = try #require(result)
        #expect(ranked.isModelRanked)
        #expect(ranked.candidates.contains { $0.modelRankingScore != nil })
        let orderedScores = ranked.candidates.compactMap(\.modelRankingScore)
        #expect(orderedScores == orderedScores.sorted(by: >))
        #expect(ranked.candidates.last?.text == "fangan")
        #expect(ranked.candidates.last?.isLiteral == true)

        var navigating = session
        let preview = request.generatePreview()
        let acceptedPreview = navigating.accept(preview)
        let keptPreview = navigating.retainPreview(insteadOf: ranked)
        #expect(acceptedPreview && keptPreview)
        #expect(navigating.candidates == preview.candidates)
        #expect(navigating.pendingCandidateRequest == nil)

        var secure = session
        secure.configure(languages: [.simplifiedChinese, .english], experimentalRankingEnabled: false)
        let acceptedBeforeDisable = secure.accept(ranked)
        #expect(!acceptedBeforeDisable)
        let protectedRequest = try #require(secure.pendingCandidateRequest)
        #expect(!protectedRequest.generate(useExperimentalRanking: true).isModelRanked)

        let accepted = session.accept(ranked)
        #expect(accepted)

        var selection = CandidateSelection()
        selection.update(session.candidates)
        let displayed = try #require(selection.candidates.first { $0.modelRankingScore != nil })
        var standard = session
        let ordinary = standard.commitResult(displayed, reason: selection.confirmationReason(for: displayed))
        #expect(ordinary.text == displayed.text)

        #expect(ranked.candidates.filter { !$0.isLiteral }.allSatisfy { $0.statisticalScore != nil })
        let acceptedOld = session.accept(ranked)
        #expect(!acceptedOld)
    }

    @Test func latestHintsRefreshWhileAnObsoleteFinalSearchIsStillBlocked() async throws {
        let fullGate = Gate()
        let previewGate = Gate()
        var session = InputSession(candidateGeneration: .deferred)
        let full = CandidatePipeline(generate: { await fullGate.generate($0) }) { result in
            _ = session.accept(result)
            fullGate.didReceive()
        }
        let preview = CandidatePipeline.preview { result in
            _ = session.accept(result)
            previewGate.didReceive()
        }
        session.append("ni")
        let first = try #require(session.pendingCandidateRequest)
        full.submit(first)
        await fullGate.waitForStarts(1)
        preview.submit(first)
        await previewGate.waitForReceipts(1)
        #expect(session.hasCandidatePreview && session.candidates.contains { $0.text == "你" })
        session.append("hao")
        let latest = try #require(session.pendingCandidateRequest)
        full.submit(latest)
        preview.submit(latest)
        await previewGate.waitForReceipts(2)
        #expect(fullGate.started == [first.id])
        #expect(session.hasCandidatePreview && session.candidates.contains { $0.text == "你好" })
        fullGate.release(first.id)
        await fullGate.waitForStarts(2)
        #expect(session.hasCandidatePreview && session.buffer == "nihao")
        fullGate.release(latest.id)
        await fullGate.waitForReceipts(2)
        #expect(session.pendingCandidateRequest == nil && !session.hasCandidatePreview)
        #expect(session.candidates.contains { $0.text == "你好" && !$0.isPartial })
    }

    @Test func rapidEditsRunOnlyTheInFlightAndLatestRequests() async throws {
        let gate = Gate()
        var received: [String] = []
        let pipeline = CandidatePipeline(generate: { await gate.generate($0) }) {
            received.append($0.candidates.last?.text ?? "")
            gate.didReceive()
        }
        var session = makeSession()
        session.append("a")
        let first = try #require(session.pendingCandidateRequest)
        pipeline.submit(first)
        await gate.waitForStarts(1)
        session.append("b")
        let skipped = try #require(session.pendingCandidateRequest)
        pipeline.submit(skipped)
        session.append("c")
        let latest = try #require(session.pendingCandidateRequest)
        pipeline.submit(latest)
        pipeline.submit(latest)
        gate.release(first.id)
        await gate.waitForStarts(2)
        #expect(gate.started == [first.id, latest.id])
        #expect(received == ["a"])
        gate.release(latest.id)
        await gate.waitForReceipts(2)
        #expect(received == ["a", "abc"])
    }

    @Test func cancelledCompositionAndReplacementCannotBeRestoredByOldWork() async throws {
        let gate = Gate()
        var session = makeSession()
        var accepted: [String] = []
        let pipeline = CandidatePipeline(generate: { await gate.generate($0) }) { result in
            if session.accept(result) { accepted.append(session.buffer) }
            gate.didReceive()
        }
        session.append("old")
        let old = try #require(session.pendingCandidateRequest)
        pipeline.submit(old)
        await gate.waitForStarts(1)
        session.append("discarded")
        pipeline.submit(try #require(session.pendingCandidateRequest))
        session.reset()
        pipeline.invalidate()
        session.append("new")
        let new = try #require(session.pendingCandidateRequest)
        pipeline.submit(new)
        gate.release(old.id)
        await gate.waitForStarts(2)
        #expect(accepted.isEmpty)
        #expect(gate.started == [old.id, new.id])
        gate.release(new.id)
        await gate.waitForReceipts(2)
        #expect(accepted == ["new"])
        #expect(session.candidates.last?.text == "new")
        #expect(session.pendingCandidateRequest == nil)
    }

    @Test func productionWorkerRunsProvidersOffTheMainThread() async throws {
        let gate = Gate()
        let pipeline = CandidatePipeline { result in
            #expect(result.candidates.first?.text == "off-main")
            gate.didReceive()
        }
        var session = makeSession()
        session.append("synthetic")
        pipeline.submit(try #require(session.pendingCandidateRequest))
        await gate.waitForReceipts(1)
    }

    private func makeSession() -> InputSession {
        InputSession(engine: CandidateEngine(providers: [ThreadProvider()]), candidateGeneration: .deferred)
    }

    private struct ThreadProvider: CandidateProvider {
        let language = InputLanguage.english
        func candidates(for input: String) -> [InputCandidate] {
            [InputCandidate(text: Thread.isMainThread ? "on-main" : "off-main", language: language, score: 100)]
        }
    }

    @MainActor
    private final class Gate {
        private(set) var started: [UUID] = []
        private var waiting: [UUID: (CandidateRequest, CheckedContinuation<CandidateResult, Never>)] = [:]
        private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
        private var receiptWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
        private var receipts = 0

        func generate(_ request: CandidateRequest) async -> CandidateResult {
            await withCheckedContinuation { continuation in
                waiting[request.id] = (request, continuation)
                started.append(request.id)
                let ready = startWaiters.filter { $0.0 <= started.count }
                startWaiters.removeAll { $0.0 <= started.count }
                ready.forEach { $0.1.resume() }
            }
        }

        func release(_ id: UUID) {
            let value = waiting.removeValue(forKey: id)!
            value.1.resume(returning: value.0.generate())
        }

        func waitForStarts(_ count: Int) async {
            guard started.count < count else { return }
            await withCheckedContinuation { startWaiters.append((count, $0)) }
        }

        func didReceive() {
            receipts += 1
            let ready = receiptWaiters.filter { $0.0 <= receipts }
            receiptWaiters.removeAll { $0.0 <= receipts }
            ready.forEach { $0.1.resume() }
        }

        func waitForReceipts(_ count: Int) async {
            guard receipts < count else { return }
            await withCheckedContinuation { receiptWaiters.append((count, $0)) }
        }
    }
}
