import Foundation
#if SWIFT_PACKAGE
import SICore
#endif

/// One running and one latest comparison per client. Results cannot revive an invalidated view.
@MainActor
final class CandidateRerankingPipeline {
    typealias Scorer = @Sendable ([InputCandidate]) async throws -> [String: Double]
    private struct Request {
        let id: UUID
        let candidates: [InputCandidate]
        let weight: Double
    }
    private let score: Scorer
    private let receive: @MainActor (UUID, CandidateFusion?) -> Void
    private var pending: Request?
    private var currentID: UUID?
    private var runner: Task<Void, Never>?

    init(score: @escaping Scorer = { try await SmallReranker.shared.scores(for: $0) },
         receive: @escaping @MainActor (UUID, CandidateFusion?) -> Void) {
        self.score = score
        self.receive = receive
    }

    func submit(id: UUID, candidates: [InputCandidate], weight: Double) {
        currentID = id
        pending = Request(id: id, candidates: candidates, weight: weight)
        guard runner == nil else { return }
        runner = Task { [weak self] in
            while let self, let request = self.pending {
                self.pending = nil
                let result = try? await self.score(request.candidates)
                if self.currentID == request.id {
                    self.receive(request.id, result.map {
                        CandidateFusion(candidates: request.candidates, logProbabilities: $0, weight: request.weight)
                    })
                }
            }
            self?.runner = nil
        }
    }

    func invalidate() {
        currentID = nil
        pending = nil
    }
}
