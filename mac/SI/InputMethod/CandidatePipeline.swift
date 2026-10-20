import Foundation
#if SWIFT_PACKAGE
import SICore
#endif

// Serial computation shares no composition or client state between controllers.
private actor CandidateWorker {
    static let shared = CandidateWorker()
    func generate(_ request: CandidateRequest) async -> CandidateResult { request.generate() }
}

// A full search must not hold early hints behind obsolete, expensive work.
private actor CandidatePreviewWorker {
    static let shared = CandidatePreviewWorker()
    func generate(_ request: CandidateRequest) async -> CandidateResult { request.generatePreview() }
}

/// At most one running request and one latest replacement per client; no per-keystroke task backlog.
@MainActor
final class CandidatePipeline {
    typealias Generator = @Sendable (CandidateRequest) async -> CandidateResult
    private let generate: Generator
    private let receive: @MainActor (CandidateResult) -> Void
    private var pending: CandidateRequest?
    private var runningID: UUID?
    private var runner: Task<Void, Never>?

    static func preview(receive: @escaping @MainActor (CandidateResult) -> Void) -> CandidatePipeline {
        CandidatePipeline(generate: { await CandidatePreviewWorker.shared.generate($0) }, receive: receive)
    }

    init(generate: @escaping Generator = { await CandidateWorker.shared.generate($0) },
         receive: @escaping @MainActor (CandidateResult) -> Void) {
        self.generate = generate
        self.receive = receive
    }

    func submit(_ request: CandidateRequest) {
        guard pending?.id != request.id, runningID != request.id else { return }
        pending = request
        guard runner == nil else { return }
        runner = Task(priority: .userInitiated) { [weak self] in
            while let self, let request = self.pending {
                self.pending = nil
                self.runningID = request.id
                let result = await self.generate(request)
                self.receive(result)
                self.runningID = nil
            }
            self?.runner = nil
        }
    }

    func invalidate() {
        // The already-running immutable snapshot may finish, but the session rejects its revision.
        // Retain this runner until completion so replacing work cannot create concurrent searches.
        pending = nil
    }
}
