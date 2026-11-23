/// The input window and offline evaluation use SI engine's shared shortlist policy.
public enum CandidateShortlist {
    public static let ordinaryCandidateLimit = RustCandidatePresentation.limits.ordinary
    public static let wordCandidateLimit = RustCandidatePresentation.limits.words

    public static func candidates(from candidates: [InputCandidate]) -> [InputCandidate] {
        RustCandidatePresentation.shortlist(candidates)
    }
}
