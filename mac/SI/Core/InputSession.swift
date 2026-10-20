import Foundation

/// Immutable, transient work for one composition revision. No client/UI objects cross this boundary.
public struct CandidateRequest: Sendable {
    public let id = UUID()
    fileprivate let input: String
    fileprivate let languages: Set<InputLanguage>
    fileprivate let engine: CandidateEngine
    fileprivate let learning: LearningProfile
    fileprivate let dictionary: UserDictionary
    fileprivate let now: Date
    fileprivate let context: CandidateContext?

    public func generate() -> CandidateResult {
        CandidateResult(requestID: id, candidates: engine.candidates(
            for: input, languages: languages, learning: learning, dictionary: dictionary, now: now, context: context))
    }

    public func generatePreview() -> CandidateResult {
        CandidateResult(requestID: id, candidates: engine.previewCandidates(
            for: input, languages: languages, learning: learning, dictionary: dictionary, now: now, context: context),
            isPreview: true)
    }
}

public struct CandidateResult: Sendable {
    fileprivate let requestID: UUID
    public let candidates: [InputCandidate]
    public let isPreview: Bool

    fileprivate init(requestID: UUID, candidates: [InputCandidate], isPreview: Bool = false) {
        self.requestID = requestID
        self.candidates = candidates
        self.isPreview = isPreview
    }
}

public struct InputSession: Sendable {
    public enum CandidateGeneration: Sendable { case synchronous, deferred }
    public static let contextLifetime: TimeInterval = 5 * 60
    private struct RecentContext: Sendable {
        let candidate: CandidateContext
        let committedAt: Date
    }
    public private(set) var buffer = ""
    public private(set) var cursor = 0
    public var cursorUTF16Offset: Int { buffer.prefix(cursor).utf16.count }
    public private(set) var candidates: [InputCandidate] = []
    public private(set) var pendingCandidateRequest: CandidateRequest?
    public private(set) var hasCandidatePreview = false
    private var languages: Set<InputLanguage> = Set(InputLanguage.allCases)
    private let engine: CandidateEngine
    private let candidateGeneration: CandidateGeneration
    private var learning = LearningProfile()
    private var dictionary = UserDictionary()
    private var usesContext = false
    private var recentContext: RecentContext?
    private var contextGeneration: UInt64 = 0

    public init(engine: CandidateEngine = CandidateEngine(), candidateGeneration: CandidateGeneration = .synchronous) {
        self.engine = engine
        self.candidateGeneration = candidateGeneration
    }

    public mutating func configure(languages: Set<InputLanguage>, learning: LearningProfile = LearningProfile(),
                                   dictionary: UserDictionary = UserDictionary(), usesContext: Bool = false,
                                   contextGeneration: UInt64 = 0, now: Date = .now) {
        let languagesChanged = self.languages != languages
        let contextChanged = self.contextGeneration != contextGeneration
        let expired = recentContext.map { now.timeIntervalSince($0.committedAt) >= Self.contextLifetime || now < $0.committedAt } ?? false
        if expired { recentContext = nil }
        guard self.languages != languages || self.learning != learning || self.dictionary != dictionary
                || self.usesContext != usesContext || contextChanged || expired else { return }
        self.languages = languages
        self.learning = learning
        self.dictionary = dictionary
        self.usesContext = usesContext
        self.contextGeneration = contextGeneration
        if !usesContext || languagesChanged || contextChanged { recentContext = nil }
        refresh(now: now)
    }

    public mutating func append(_ text: String) {
        guard !text.isEmpty else { return }
        let insertionEnd = cursorUTF16Offset + text.utf16.count
        let index = buffer.index(buffer.startIndex, offsetBy: cursor)
        buffer.insert(contentsOf: text, at: index)
        // Inserted scalars can join adjacent graphemes (accents, flags, emoji ZWJ sequences).
        // Place the caret at the next whole-character boundary, rather than counting fragments.
        cursor = 0
        var utf16Offset = 0
        for character in buffer {
            guard utf16Offset < insertionEnd else { break }
            utf16Offset += String(character).utf16.count
            cursor += 1
        }
        refresh()
    }

    public mutating func deleteBackward() {
        guard cursor > 0 else { return }
        let index = buffer.index(buffer.startIndex, offsetBy: cursor - 1)
        buffer.remove(at: index)
        cursor -= 1
        refresh()
    }

    public mutating func deleteForward() {
        guard cursor < buffer.count else { return }
        buffer.remove(at: buffer.index(buffer.startIndex, offsetBy: cursor))
        refresh()
    }

    public mutating func moveCursor(by offset: Int) {
        cursor += max(-cursor, min(offset, buffer.count - cursor))
    }

    public mutating func moveToStart() { cursor = 0 }
    public mutating func moveToEnd() { cursor = buffer.count }

    @discardableResult
    public mutating func commit(_ candidate: InputCandidate? = nil) -> String {
        commitResult(candidate, reason: candidate == nil ? .literal : .explicitSelection).text
    }

    public mutating func commitResult(_ candidate: InputCandidate? = nil, reason: CommitReason, now: Date = .now) -> InputCommit {
        var requestedCandidate = candidate
        if hasCandidatePreview, let candidate {
            if candidates.contains(candidate) {
                resolveCandidates()
                requestedCandidate = candidates.first { $0.id == candidate.id }
            } else { requestedCandidate = nil }
        }
        let validCandidate = requestedCandidate.flatMap { value -> InputCandidate? in
            guard candidates.contains(value) else { return nil }
            if let count = value.consumedInputCount, count <= 0 || count >= buffer.count { return nil }
            return value
        }
        let count = validCandidate?.consumedInputCount ?? buffer.count
        let remaining = String(buffer.dropFirst(count))
        let remainingCursor = max(0, cursor - count)
        let result = InputCommit(input: String(buffer.prefix(count)), candidate: validCandidate,
                                 reason: validCandidate == nil ? .literal : reason, context: currentContext(now: now),
                                 remainingInput: remaining)
        reset()
        if usesContext, reason.learningWeight > 0, let validCandidate,
           let context = CandidateContext(candidate: validCandidate) {
            recentContext = RecentContext(candidate: context, committedAt: now)
        }
        buffer = remaining
        cursor = min(remainingCursor, remaining.count)
        if !remaining.isEmpty { refresh(now: now) }
        return result
    }

    public mutating func reset() {
        buffer = ""
        cursor = 0
        candidates = []
        pendingCandidateRequest = nil
        hasCandidatePreview = false
        recentContext = nil
    }

    public mutating func breakContext() {
        guard recentContext != nil else { return }
        recentContext = nil
        refresh()
    }

    /// Presentation may feature prefixes across spans using the same consent/context-aware score.
    public func presentationScore(for candidate: InputCandidate, now: Date = .now) -> Double {
        let spelling = candidate.consumedInputCount.map { String(buffer.prefix($0)) } ?? buffer
        return learning.rankingScore(for: candidate, input: spelling, now: now, context: currentContext(now: now))
    }

    private func currentContext(now: Date = .now) -> CandidateContext? {
        guard usesContext, let recentContext, now >= recentContext.committedAt,
              now.timeIntervalSince(recentContext.committedAt) < Self.contextLifetime else { return nil }
        return recentContext.candidate
    }

    private mutating func refresh(now: Date = .now) {
        guard !buffer.isEmpty else {
            candidates = []
            pendingCandidateRequest = nil
            hasCandidatePreview = false
            return
        }
        let request = CandidateRequest(input: buffer, languages: languages, engine: engine, learning: learning,
                                       dictionary: dictionary, now: now, context: currentContext(now: now))
        pendingCandidateRequest = request
        hasCandidatePreview = false
        if candidateGeneration == .synchronous {
            _ = accept(request.generate())
        } else {
            // Old candidates must not be selected while new work is pending. Exact text remains available.
            candidates = [InputCandidate(text: buffer, language: nil, score: 0)]
        }
    }

    @discardableResult
    public mutating func accept(_ result: CandidateResult) -> Bool {
        guard pendingCandidateRequest?.id == result.requestID else { return false }
        if result.isPreview && hasCandidatePreview { return false }
        candidates = result.candidates
        hasCandidatePreview = result.isPreview
        if !result.isPreview { pendingCandidateRequest = nil }
        return true
    }

    /// Selection boundaries need current candidates even when background work has not finished.
    public mutating func resolveCandidates() {
        guard let request = pendingCandidateRequest else { return }
        _ = accept(request.generate())
    }
}
