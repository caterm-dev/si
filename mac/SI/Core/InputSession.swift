public struct InputSession: Sendable {
    public private(set) var buffer = ""
    public private(set) var candidates: [InputCandidate] = []
    private var languages: Set<InputLanguage> = Set(InputLanguage.allCases)
    private let engine: CandidateEngine

    public init(engine: CandidateEngine = CandidateEngine()) {
        self.engine = engine
    }

    public mutating func configure(languages: Set<InputLanguage>) {
        self.languages = languages
        refresh()
    }

    public mutating func append(_ text: String) {
        buffer += text
        refresh()
    }

    public mutating func deleteBackward() {
        guard !buffer.isEmpty else { return }
        buffer.removeLast()
        refresh()
    }

    @discardableResult
    public mutating func commit(_ candidate: InputCandidate? = nil) -> String {
        let text = candidate.flatMap { candidates.contains($0) ? $0.text : nil } ?? buffer
        reset()
        return text
    }

    public mutating func reset() {
        buffer = ""
        candidates = []
    }

    private mutating func refresh() {
        candidates = engine.candidates(for: buffer, languages: languages)
    }
}
