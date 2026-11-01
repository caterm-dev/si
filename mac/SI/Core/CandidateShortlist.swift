/// The input window and offline quality evaluation share this exact ordered shortlist.
public enum CandidateShortlist {
    public static let ordinaryCandidateLimit = 27
    private static let leadingChoices = 4

    private static func isWord(_ candidate: InputCandidate) -> Bool {
        !candidate.isLiteral && !candidate.isMixed && !candidate.hasLiteralSegments
            && (candidate.lexicalTokenCount == 1 || candidate.isUserPhrase || candidate.isPunctuation)
    }

    public static func candidates(from candidates: [InputCandidate]) -> [InputCandidate] {
        let ordinary = candidates.filter { !$0.isLiteral }
        // Only the first four ranked choices can add ordinary constructed results.
        // Every language uses the same ranked head and ordinary word budget.
        let leadingIDs = Set(ordinary.prefix(leadingChoices).filter { !isWord($0) }.map(\.id))
        let literal = candidates.filter(\.isLiteral)
        var retained = leadingIDs.union(literal.map(\.id))
        for candidate in candidates where isWord(candidate) {
            guard retained.count < ordinaryCandidateLimit else { break }
            retained.insert(candidate.id)
        }
        // Pagination exposes every generated dictionary character, independently
        // of the ordinary word budget. Search and sentence beams stay bounded.
        for candidate in ordinary where candidate.language == .simplifiedChinese
            && !candidate.isMixed && !candidate.isUserPhrase && !candidate.isPunctuation
            && candidate.lexicalTokenCount == 1 && candidate.text.count == 1 {
            retained.insert(candidate.id)
        }
        let result = ordinary.filter { retained.contains($0.id) }
        return result + literal
    }
}
