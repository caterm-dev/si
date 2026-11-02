import Foundation

/// Independent text-only LM ranking. Never changes candidate identity or commit bytes.
public struct CandidateFusion: Sendable {
    public static let maximumCandidates = 32
    public let candidates: [InputCandidate]
    /// Weighted mean log probability in bits per Unicode scalar; higher is better.
    /// Missing entries were not scored and must not be presented as model results.
    public let scores: [String: Double]

    public static func eligible(_ candidate: InputCandidate) -> Bool {
        !candidate.isLiteral && !candidate.isUserPhrase && !candidate.hasLiteralSegments
            && !candidate.isPartial && !candidate.hasCompletion && !candidate.isPunctuation
    }

    public init(candidates: [InputCandidate], logProbabilities: [String: Double], weight: Double) {
        let weight = weight.isFinite ? min(2, max(0, weight)) : 0
        var scores: [String: Double] = [:]
        for candidate in candidates {
            if Self.eligible(candidate), let probability = logProbabilities[candidate.id],
               probability.isFinite, probability <= 0, !candidate.text.isEmpty {
                // Keep the model's full ordering, including below the former reward
                // clamp. Engine scores must not override unequal model evidence.
                let mean = probability / Double(candidate.text.unicodeScalars.count) / log(2)
                scores[candidate.id] = weight * mean
            }
        }
        self.scores = scores
        guard weight > 0 else {
            self.candidates = candidates
            return
        }
        self.candidates = candidates.enumerated().sorted { left, right in
            let a = left.element, b = right.element
            if a.isLiteral != b.isLiteral { return !a.isLiteral }
            if a.isPreferred != b.isPreferred { return a.isPreferred }
            if a.isRememberedChoice != b.isRememberedChoice { return a.isRememberedChoice }
            // Unscored paths retain their relative engine order after scored choices.
            let sa = scores[a.id] ?? -.infinity, sb = scores[b.id] ?? -.infinity
            if sa != sb { return sa > sb }
            return left.offset < right.offset
        }.map(\.element)
    }
}
