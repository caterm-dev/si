import Foundation
import Testing
import SICore
@testable import SIPresentation

@MainActor
struct CandidatePipelineTests {
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
