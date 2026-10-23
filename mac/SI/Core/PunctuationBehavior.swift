public enum PunctuationBehavior: String, CaseIterable, Identifiable, Sendable {
    case smart
    case asTyped
    case confirmCandidate

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .smart: "Smart Chinese Punctuation"
        case .asTyped: "Keep Composing"
        case .confirmCandidate: "Confirm Candidate"
        }
    }
    public var explanation: String {
        switch self {
        case .smart:
            "Optional: common punctuation and Tab confirm a whole Chinese or mixed candidate. Chinese endings use Chinese punctuation. ASCII periods and non-confirming symbols stay editable in the composition. Unselected English completions and partial personal codes are not confirmed."
        case .asTyped:
            "Keep punctuation and symbols editable without confirming a candidate. Common trailing punctuation offers English and Chinese alternatives for complete words, with the original spelling available. Continue typing domains, email addresses and code. Tab commits the original spelling and passes through."
        case .confirmCandidate:
            "Optional: common punctuation and Tab confirm a whole Chinese or mixed candidate and keep punctuation unchanged. ASCII periods and non-confirming symbols stay editable in the composition. English words and partial personal codes are not confirmed unless actively selected."
        }
    }
}
