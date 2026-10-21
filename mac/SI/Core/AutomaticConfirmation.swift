import Foundation

/// Client-local, bounded evidence for implicit acceptance. Scores are relative model scores,
/// not calibrated probabilities. Only full, current searches may supply observations.
struct AutomaticConfirmation: Sendable {
    static let pauseDelay: TimeInterval = 1.8
    private static let competitorMargin = 3.0

    struct Prefix: Sendable {
        let candidate: InputCandidate
        let remainingCharacters: Int
        let remainingLetters: Int
    }

    private struct Observation: Sendable {
        let prefix: Prefix
        let firstInputLength: Int
        let firstSeen: Date
        let samples: Int
    }

    private var observations: [Observation] = []
    private var lastObservedInput = ""
    private var lastEdit: Date?
    private var inputLength = 0
    private var isSuspended = false

    mutating func appended(input: String, atEnd: Bool, now: Date) {
        guard atEnd else { suspend(); return }
        if let lastEdit, now < lastEdit { observations = [] }
        self.lastEdit = now
        inputLength = input.count
        isSuspended = false
    }

    mutating func suspend() {
        isSuspended = true
        observations = []
        lastObservedInput = ""
        lastEdit = nil
    }

    mutating func observe(_ prefixes: [Prefix], input: String, now: Date) {
        guard !isSuspended, lastEdit != nil, input != lastObservedInput else { return }
        let previous = observations
        observations = prefixes.map { prefix in
            let old = previous.first { $0.prefix.candidate.id == prefix.candidate.id }
            return Observation(prefix: prefix, firstInputLength: old?.firstInputLength ?? inputLength,
                               firstSeen: old?.firstSeen ?? now, samples: (old?.samples ?? 0) + 1)
        }
        lastObservedInput = input
    }

    func candidate(now: Date, afterPause: Bool) -> InputCandidate? {
        guard !isSuspended, let lastEdit, now >= lastEdit else { return nil }
        if afterPause && now.timeIntervalSince(lastEdit) < Self.pauseDelay { return nil }
        return observations.last { observation in
            let prefix = observation.prefix
            guard now >= observation.firstSeen else { return false }
            if afterPause {
                return prefix.candidate.text.count >= 2
                    && prefix.remainingCharacters >= 2 && prefix.remainingLetters >= 4
                    && now.timeIntervalSince(observation.firstSeen) >= 0.6
            }
            return prefix.remainingCharacters >= 4 && prefix.remainingLetters >= 8
                && observation.samples >= 2 && inputLength - observation.firstInputLength >= 6
        }?.prefix.candidate
    }

    var hasPauseCandidate: Bool {
        !isSuspended && observations.contains {
            $0.prefix.candidate.text.count >= 2 && $0.prefix.remainingCharacters >= 2 && $0.prefix.remainingLetters >= 4
        }
    }

    /// Runs on the candidate worker. No new decoding, profile scan, host text, or disk access.
    static func prefixes(for candidates: [InputCandidate], input: String, learning: LearningProfile,
                         now: Date, context: CandidateContext?) -> [Prefix] {
        guard input == input.lowercased(), let reading = PinyinInput(input),
              let leader = candidates.first(where: { !$0.isPartial && !$0.isLiteral }),
              leader.language == .simplifiedChinese, !leader.isMixed, !leader.isUserPhrase, !leader.hasLiteralSegments,
              !leader.confirmationBoundaries.isEmpty else { return [] }
        // Language selection must not remove code/English safeguards. Only test established Chinese
        // word boundaries: scanning every letter would mistake the overlapping "open" in nihaopengyou.
        for boundary in leader.confirmationBoundaries {
            guard let start = reading.rawBoundaries.firstIndex(of: boundary.sourceCount),
                  start < reading.letters.count, !reading.separators.contains(start) else { continue }
            var node = 0
            for end in start..<min(reading.letters.count, start + EnglishLexicon.maximumLength) {
                if end > start && reading.separators.contains(end) { break }
                guard let next = EnglishLexicon.advance(node, byte: reading.letters[end].asciiValue!) else { break }
                node = next
                if end - start + 1 >= 4 && EnglishLexicon.exactMatch(at: node) != nil { return [] }
            }
        }
        let ranking = learning.ranking(for: input, now: now, context: context)
        let threshold = ranking.score(leader) - competitorMargin
        let competitors = candidates.filter {
            !$0.isLiteral && !$0.isPartial && (ranking.score($0) >= threshold || $0.isPreferred)
        }
        var result: [Prefix] = []
        for boundary in leader.confirmationBoundaries where boundary.sourceCount < input.count {
            guard boundary.sourceCount > 0, boundary.outputByteCount < leader.text.utf8.count,
                  let end = prefixEnd(in: leader.text, byteCount: boundary.outputByteCount),
                  let consumedLetters = reading.rawBoundaries.firstIndex(of: boundary.sourceCount) else { continue }
            let text = String(leader.text[..<end])
            // Require exact output bytes AND the same source boundary on every plausible path.
            // A string prefix alone can conceal a different Pinyin segmentation.
            guard competitors.allSatisfy({ candidate in
                candidate.confirmationBoundaries.contains(boundary)
                    && candidate.text.utf8.starts(with: text.utf8)
                    && prefixEnd(in: candidate.text, byteCount: boundary.outputByteCount) != nil
                    && !candidate.isUserPhrase && !candidate.hasLiteralSegments
            }) else { continue }
            result.append(Prefix(candidate: InputCandidate(text: text, language: .simplifiedChinese,
                                                           score: leader.score, consumedInputCount: boundary.sourceCount),
                                 remainingCharacters: leader.text[end...].count,
                                 remainingLetters: reading.letters.count - consumedLetters))
        }
        return result
    }

    private static func prefixEnd(in text: String, byteCount: Int) -> String.Index? {
        guard byteCount > 0, byteCount <= text.utf8.count,
              let index = String.Index(text.utf8.index(text.utf8.startIndex, offsetBy: byteCount), within: text),
              text.isCharacterBoundary(index) else { return nil }
        return index
    }
}

private extension String {
    func isCharacterBoundary(_ index: Index) -> Bool {
        index == endIndex || indices.contains(index)
    }
}
