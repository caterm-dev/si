/// The input window and offline quality evaluation share this exact ordered shortlist.
public enum CandidateShortlist {
    public static let maximumCandidates = 27

    private static func protectedIDs(_ engineCandidates: [InputCandidate]) -> Set<String> {
        // Reserve a complete choice per language identity before considering prefix-only fallbacks.
        var languages: Set<InputLanguage> = []
        var includesMixed = false
        var retainedIDs: Set<String> = []
        if let history = engineCandidates.first(where: \.isHistory) { retainedIDs.insert(history.id) }
        // The decoder emits at most six base and six personalized readings. Moving
        // runner-ups behind word choices must not make those readings unreachable.
        for sentence in engineCandidates.filter(\.isChineseSentence).prefix(12) {
            retainedIDs.insert(sentence.id)
        }
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
        guard candidates.count > maximumCandidates else { return orderSentenceReadings(candidates) }
        var retainedIDs = protectedIDs(candidates)
        for candidate in candidates {
            guard retainedIDs.count < maximumCandidates else { break }
            retainedIDs.insert(candidate.id)
        }
        return orderSentenceReadings(candidates.filter { retainedIDs.contains($0.id) })
    }

    /// MSIME's runner-up policy, adapted to SI's literal and app-history contracts.
    /// Keep three readings of at least three characters, otherwise one, beside the
    /// first reading. Move the rest behind ordinary choices without changing scores.
    private static func orderSentenceReadings(_ candidates: [InputCandidate]) -> [InputCandidate] {
        guard let first = candidates.first(where: \.isChineseSentence) else { return candidates }
        let width = first.text.count
        guard width >= 2 else { return candidates }
        func isReading(_ candidate: InputCandidate) -> Bool {
            candidate.isChineseSentence && candidate.text.count == width
        }
        let readings = candidates.filter(isReading)
        let keep = width >= 3 ? 3 : 1
        guard readings.count > 1 else { return candidates }
        var result: [InputCandidate] = []
        for candidate in candidates where !candidate.isLiteral && !candidate.isHistory {
            if candidate.id == first.id { result += readings.prefix(keep) }
            else if !isReading(candidate) { result.append(candidate) }
        }
        result += readings.dropFirst(keep)
        let history = candidates.filter(\.isHistory)
        if !history.isEmpty {
            let whole = result.indices.filter { !result[$0].isPartial }
            let insertion = whole.prefix(2).last.map { $0 + 1 } ?? 0
            result.insert(contentsOf: history, at: insertion)
        }
        // Exact input remains the final explicit choice in every layout.
        return result + candidates.filter(\.isLiteral)
    }
}
