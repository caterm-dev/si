public struct BoundaryResolution: Sendable {
    public let candidate: InputCandidate?
    /// A replacement consumes the original key. Nil passes it through only when composition ends.
    public let replacement: String?
    /// Append this key to the marked spelling instead of committing or passing it through.
    public let continuesComposition: Bool

    public init(candidate: InputCandidate? = nil, replacement: String? = nil, continuesComposition: Bool = false) {
        self.candidate = candidate
        self.replacement = replacement
        self.continuesComposition = continuesComposition
    }
}
