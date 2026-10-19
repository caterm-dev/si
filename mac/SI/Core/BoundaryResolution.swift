public struct BoundaryResolution: Sendable {
    public let candidate: InputCandidate?
    /// A replacement consumes the original key. Nil leaves it for the host application.
    public let replacement: String?

    public init(candidate: InputCandidate? = nil, replacement: String? = nil) {
        self.candidate = candidate
        self.replacement = replacement
    }
}
