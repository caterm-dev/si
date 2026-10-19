import Foundation

public struct InputSession: Sendable {
    public static let contextLifetime: TimeInterval = 5 * 60
    private struct RecentContext: Sendable {
        let candidate: CandidateContext
        let committedAt: Date
    }
    public private(set) var buffer = ""
    public private(set) var cursor = 0
    public var cursorUTF16Offset: Int { buffer.prefix(cursor).utf16.count }
    public private(set) var candidates: [InputCandidate] = []
    private var languages: Set<InputLanguage> = Set(InputLanguage.allCases)
    private let engine: CandidateEngine
    private var learning = LearningProfile()
    private var dictionary = UserDictionary()
    private var usesContext = false
    private var recentContext: RecentContext?
    private var contextGeneration: UInt64 = 0

    public init(engine: CandidateEngine = CandidateEngine()) {
        self.engine = engine
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
        let validCandidate = candidate.flatMap { value -> InputCandidate? in
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
        recentContext = nil
    }

    public mutating func breakContext() {
        guard recentContext != nil else { return }
        recentContext = nil
        refresh()
    }

    private func currentContext(now: Date = .now) -> CandidateContext? {
        guard usesContext, let recentContext, now >= recentContext.committedAt,
              now.timeIntervalSince(recentContext.committedAt) < Self.contextLifetime else { return nil }
        return recentContext.candidate
    }

    private mutating func refresh(now: Date = .now) {
        candidates = engine.candidates(for: buffer, languages: languages, learning: learning, dictionary: dictionary,
                                       now: now, context: currentContext(now: now))
    }
}
