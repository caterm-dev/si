public enum CommitReason: String, Sendable {
    case explicitSelection
    case defaultAcceptance
    case literal
    case focusChange
    case passthrough

    /// Default acceptance is weaker evidence because the candidate already occupied first place.
    public var learningWeight: Double {
        switch self {
        case .explicitSelection: 1
        case .defaultAcceptance: 0.15
        case .literal, .focusChange, .passthrough: 0
        }
    }
}
