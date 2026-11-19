/// The input window and offline quality evaluation share this exact ordered shortlist.
public enum CandidateShortlist {
    public static let ordinaryCandidateLimit = 27
    public static let wordCandidateLimit = 9
    private static let leadingChoices = 4

    private static func isWord(_ candidate: InputCandidate) -> Bool {
        !candidate.isLiteral && !candidate.isPinyinCorrection && !candidate.isMixed && !candidate.hasLiteralSegments && !candidate.hasCompletion
            && (candidate.lexicalTokenCount == 1 || candidate.isUserPhrase || candidate.isPunctuation)
    }

    private static func isDictionaryCharacter(_ candidate: InputCandidate) -> Bool {
        isWord(candidate) && candidate.language == .simplifiedChinese
            && !candidate.isUserPhrase && !candidate.isPunctuation && candidate.text.count == 1
    }

    public static func candidates(from candidates: [InputCandidate]) -> [InputCandidate] {
        let ordinary = candidates.filter { !$0.isLiteral }
        // Only the first four ranked choices can add constructed results or completions.
        // Every language uses the same ranked head and ordinary word budget.
        let leadingIDs = Set(ordinary.lazy.filter { !$0.isPinyinCorrection }
            .prefix(leadingChoices).filter { !isWord($0) }.map(\.id))
        let literal = candidates.filter(\.isLiteral)
        var retained = leadingIDs.union(literal.map(\.id))
        // Rust bounds suggestions separately. They share the overall capacity,
        // without consuming ordinary word slots.
        var wordCount = 0
        for candidate in ordinary where candidate.isPinyinCorrection || (isWord(candidate) && !isDictionaryCharacter(candidate)) {
            guard retained.count < ordinaryCandidateLimit else { break }
            guard candidate.isPinyinCorrection || candidate.isPunctuation || wordCount < wordCandidateLimit else { continue }
            retained.insert(candidate.id)
            if !candidate.isPunctuation && !candidate.isPinyinCorrection { wordCount += 1 }
        }
        // Pagination exposes every generated dictionary character, independently
        // of the ordinary word budget. Search and sentence beams stay bounded.
        for candidate in ordinary where isDictionaryCharacter(candidate) {
            retained.insert(candidate.id)
        }
        let result = ordinary.filter { retained.contains($0.id) }
        return result + literal
    }
}
