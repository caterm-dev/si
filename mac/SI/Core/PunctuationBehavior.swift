public enum PunctuationBehavior: String, CaseIterable, Identifiable, Sendable {
    case smart
    case asTyped
    case confirmCandidate

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .smart: "Smart Chinese Punctuation"
        case .asTyped: "Keep Typed Text"
        case .confirmCandidate: "Confirm Candidate"
        }
    }
    public var explanation: String {
        switch self {
        case .smart:
            "While composing, common punctuation and Tab confirm a whole Chinese or mixed candidate. Chinese endings use Chinese punctuation. ASCII periods always keep the original spelling. Unselected English completions, partial personal codes, and code separators stay as typed."
        case .asTyped:
            "Punctuation and Tab keep the composition exactly as typed, then pass the key to the application."
        case .confirmCandidate:
            "While composing, common punctuation and Tab confirm a whole Chinese or mixed candidate and keep punctuation unchanged. ASCII periods always keep the original spelling. English words and partial personal codes stay as typed unless actively selected."
        }
    }
}
