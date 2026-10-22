import Foundation
import Observation
#if SWIFT_PACKAGE
import SICore
#endif

/// At most one running request and one latest replacement. Preview never records learning.
@MainActor
@Observable
final class CandidatePreviewModel {
    private(set) var candidates: [InputCandidate] = []
    private(set) var isSearching = false
    @ObservationIgnored private let worker = CandidatePreviewSearch()
    @ObservationIgnored private var revision = UUID()
    @ObservationIgnored private var pending: (id: UUID, query: CandidatePreviewQuery, isCurrent: @MainActor () -> Bool)?
    @ObservationIgnored private var runner: Task<Void, Never>?

    func submit(_ query: CandidatePreviewQuery, isCurrent: @escaping @MainActor () -> Bool) {
        revision = UUID()
        pending = (revision, query, isCurrent)
        candidates = query.input.isEmpty ? [] : [InputCandidate(text: query.input, language: nil, score: 0)]
        isSearching = !query.input.isEmpty
        guard runner == nil else { return }
        runner = Task(priority: .userInitiated) { [weak self] in
            while let self, let request = self.pending {
                self.pending = nil
                let result = await self.worker.generate(request.query)
                guard !Task.isCancelled else { break }
                if self.revision == request.id {
                    // Secure input and consent are read again at delivery, even if no view
                    // invalidation occurred while the worker was searching.
                    self.candidates = request.isCurrent() ? result : []
                    self.isSearching = false
                }
            }
            self?.runner = nil
        }
    }

    func cancel() {
        revision = UUID()
        pending = nil
        candidates = []
        isSearching = false
    }
}
