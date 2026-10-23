/// The input window and offline quality evaluation share this exact ordered shortlist.
public enum CandidateShortlist {
    public static let maximumCandidates = 27

    private static func protectedIDs(_ engineCandidates: [InputCandidate]) -> Set<String> {
        // Reserve a complete choice per language identity before considering prefix-only fallbacks.
        var languages: Set<InputLanguage> = []
        var includesMixed = false
        var retainedIDs: Set<String> = []
        if let history = engineCandidates.first(where: \.isHistory) { retainedIDs.insert(history.id) }
        for partial in [false, true] {
            for candidate in engineCandidates where candidate.isPartial == partial && !candidate.isHistory {
                if candidate.isLiteral {
                    retainedIDs.insert(candidate.id)
                } else if candidate.isMixed {
                    if !includesMixed { retainedIDs.insert(candidate.id) }
                    includesMixed = true
                } else if let language = candidate.language, languages.insert(language).inserted {
                    retainedIDs.insert(candidate.id)
                }
            }
        }
        return retainedIDs
    }

    public static func candidates(from candidates: [InputCandidate]) -> [InputCandidate] {
        guard candidates.count > maximumCandidates else { return candidates }
        var retainedIDs = protectedIDs(candidates)
        for candidate in candidates {
            guard retainedIDs.count < maximumCandidates else { break }
            retainedIDs.insert(candidate.id)
        }
        return candidates.filter { retainedIDs.contains($0.id) }
    }
}
