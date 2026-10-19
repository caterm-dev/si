public struct InputCommit: Sendable {
    public let input: String
    public let text: String
    public let candidate: InputCandidate?
    public let reason: CommitReason
    public let context: CandidateContext?
    public let remainingInput: String

    public init(input: String, candidate: InputCandidate?, reason: CommitReason, context: CandidateContext? = nil,
                remainingInput: String = "") {
        self.input = input
        self.candidate = candidate
        self.text = candidate?.text ?? input
        self.reason = reason
        self.context = context
        self.remainingInput = remainingInput
    }
}
