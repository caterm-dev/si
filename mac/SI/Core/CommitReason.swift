public enum CommitReason: String, Sendable {
    case explicitSelection
    case defaultAcceptance
    case literal
    case focusChange
    case passthrough

    /// Accepting the default is not evidence of a deliberate preference.
    public var learningWeight: Double {
        switch self {
        case .explicitSelection: 1
        case .defaultAcceptance, .literal, .focusChange, .passthrough: 0
        }
    }
}
