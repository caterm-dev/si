public enum CommitReason: String, Sendable {
    case explicitSelection
    case defaultAcceptance
    case automaticConfirmation
    case aiCompletion
    case literal
    case focusChange
    case passthrough

    /// Accepting the default is not evidence of a deliberate preference.
    public var learningWeight: Double {
        switch self {
        case .explicitSelection: 1
        case .defaultAcceptance, .automaticConfirmation, .aiCompletion, .literal, .focusChange, .passthrough: 0
        }
    }
}
