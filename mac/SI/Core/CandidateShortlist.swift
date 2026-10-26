/// The input window and offline quality evaluation share this exact ordered shortlist.
public enum CandidateShortlist {
    public static let maximumCandidates = 27
    private static let leadingChoices = 4

    private static func isWord(_ candidate: InputCandidate) -> Bool {
        !candidate.isLiteral && !candidate.isHistory && !candidate.isMixed && !candidate.hasLiteralSegments
            && (candidate.lexicalTokenCount == 1 || candidate.isUserPhrase || candidate.isPunctuation)
    }

    private static func protectedIDs(_ candidates: [InputCandidate]) -> Set<String> {
        // Preserve each identity's first result and its first complete word.
        var firstLanguages: Set<InputLanguage> = []
        var wholeLanguages: Set<InputLanguage> = []
        var firstMixed = false
        var result: Set<String> = []
        for candidate in candidates {
            if candidate.isMixed {
                if !firstMixed { result.insert(candidate.id) }
                firstMixed = true
            } else if let language = candidate.language {
                if firstLanguages.insert(language).inserted { result.insert(candidate.id) }
                if !candidate.isPartial, isWord(candidate), wholeLanguages.insert(language).inserted {
                    result.insert(candidate.id)
                }
            }
        }
        return result
    }

    public static func candidates(from candidates: [InputCandidate]) -> [InputCandidate] {
        let ordinary = candidates.filter { !$0.isLiteral && !$0.isHistory }
        let protected = protectedIDs(ordinary)
        // Required constructed language choices occupy leading slots instead of
        // leaking into the word-only tail. Each group retains engine order.
        var leadingIDs = Set(ordinary.filter { protected.contains($0.id) && !isWord($0) }.map(\.id))
        for candidate in ordinary where !isWord(candidate) {
            guard leadingIDs.count < leadingChoices else { break }
            leadingIDs.insert(candidate.id)
        }
        let leading = ordinary.filter { leadingIDs.contains($0.id) }
        let words = ordinary.filter { !leadingIDs.contains($0.id) && isWord($0) }
        let history = candidates.filter(\.isHistory)
        let literal = candidates.filter(\.isLiteral)
        var retained = protected.union(leadingIDs).union(literal.map(\.id))
        if let first = history.first { retained.insert(first.id) }
        for candidate in candidates where isWord(candidate) || candidate.isHistory {
            guard retained.count < maximumCandidates else { break }
            retained.insert(candidate.id)
        }
        // A word-led query (for example ling or xianshi) keeps score order.
        // Sentence-led compositions expose four hypotheses, then only words.
        var result = ordinary.first.map(isWord) == false
            ? leading + words.filter { retained.contains($0.id) }
            : ordinary.filter { retained.contains($0.id) }
        let retainedHistory = history.filter { retained.contains($0.id) }
        if !retainedHistory.isEmpty {
            // App History keeps its separate placement after two whole choices.
            let whole = result.indices.filter { !result[$0].isPartial }
            let insertion = whole.prefix(2).last.map { $0 + 1 } ?? 0
            result.insert(contentsOf: retainedHistory, at: insertion)
        }
        return result + literal
    }
}
