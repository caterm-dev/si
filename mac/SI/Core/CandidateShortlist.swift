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
        // Corrections, constructed results and completions share the first four ranked choices.
        // Every language uses the same ranked head and ordinary word budget.
        let leadingIDs = Set(ordinary.lazy.prefix(leadingChoices).filter { !isWord($0) }.map(\.id))
        let literal = candidates.filter(\.isLiteral)
        var retained = leadingIDs.union(literal.map(\.id))
        // Keep both statistical leaders selectable while preserving the incoming order.
        var wordCount = 0
        func retainLeader(_ candidate: InputCandidate) {
            guard !isDictionaryCharacter(candidate) else { return }
            retained.insert(candidate.id)
            if isWord(candidate) && !candidate.isPunctuation { wordCount += 1 }
        }
        let statistical = ordinary.lazy.filter { $0.statisticalScore != nil }
        if let first = statistical.min(by: InputCandidate.precedesInStatistics) {
            retainLeader(first)
            if let second = statistical.lazy.filter({ $0.id != first.id }).min(by: InputCandidate.precedesInStatistics) {
                retainLeader(second)
            }
        }
        for candidate in ordinary where isWord(candidate) && !isDictionaryCharacter(candidate) {
            if retained.contains(candidate.id) { continue }
            guard retained.count < ordinaryCandidateLimit else { break }
            guard candidate.isPunctuation || wordCount < wordCandidateLimit else { continue }
            retained.insert(candidate.id)
            if !candidate.isPunctuation { wordCount += 1 }
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
