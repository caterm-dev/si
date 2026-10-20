import Foundation

/// Normalized bilingual word priors with Witten–Bell character-boundary context.
/// Context evidence is adjacent character types in the existing Chinese vocabulary,
/// never a fabricated sentence corpus. English falls back to measured unigram priors.
struct LexicalLanguageModel: Sendable {
    struct History: Sendable {
        let backoffCost: Double
        let observedCosts: [Int: Double]
    }

    static let pointsPerBit = 1.0
    let chineseIDs: [Int]
    let readingCosts: [Double]
    let costs: [Double]
    private let contextBackoff: [Double]
    private let transitions: [UInt64: Double]
    let firstCharacters: [Int]
    let lastCharacters: [Int]
    let englishLimit: Int
    private let chineseUnknown: Double
    private let englishUnknown: Double
    private let unknownCosts: [Double]
    private let languageCosts: [Double]

    init(entries: [PinyinLexiconEntry]) {
        var weights: [String: Double] = [:]
        var readings: [String: [String: Double]] = [:]
        for entry in entries {
            // A pseudocount covers missing/zero weights without changing source data.
            // The legacy score API for injected lexicons uses ten compatibility points per bit.
            let weight = entry.usesUpstreamWeight ? Double(max(1, entry.upstreamWeight ?? 0)) : exp2(Double(entry.score) / 10)
            weights[entry.text] = max(weights[entry.text, default: 0], weight)
            readings[entry.text, default: [:]][entry.code] = max(readings[entry.text]?[entry.code] ?? 0, weight)
        }
        let readingTotals = readings.mapValues { values in values.keys.sorted().reduce(0.0) { $0 + values[$1]! } }
        readingCosts = entries.map { entry in
            let weight = entry.usesUpstreamWeight ? Double(max(1, entry.upstreamWeight ?? 0)) : exp2(Double(entry.score) / 10)
            return -log2(weight / readingTotals[entry.text]!)
        }
        let texts = weights.keys.sorted()
        let offset = EnglishLexicon.entries.count + 1
        englishLimit = offset
        let ids = Dictionary(uniqueKeysWithValues: texts.enumerated().map { ($0.element, $0.offset + offset) })
        chineseIDs = entries.map { ids[$0.text]! }
        let total = texts.reduce(1.0) { $0 + weights[$1]! }
        let unknownC = 1 / total
        let unknownE = EnglishLexicon.unknownProbability
        chineseUnknown = unknownC
        englishUnknown = unknownE
        var probabilities = [0.5 * (unknownC + unknownE)]
        probabilities += EnglishLexicon.entries.map { 0.5 * $0.probability }
        probabilities += texts.map { 0.5 * weights[$0]! / total }
        costs = probabilities.map { -log2($0) }

        let characters = Set(texts.flatMap { Array($0) }).sorted { String($0) < String($1) }
        let characterIDs = Dictionary(uniqueKeysWithValues: characters.enumerated().map { ($0.element, $0.offset + 1) })
        firstCharacters = Array(repeating: 0, count: offset) + texts.map { characterIDs[$0.first!]! }
        lastCharacters = Array(repeating: 0, count: offset) + texts.map { characterIDs[$0.last!]! }
        var firstMass = [0: unknownC]
        var counts: [Int: [Int: Double]] = [:]
        for text in texts {
            let characters = Array(text)
            let first = characterIDs[characters[0]]!
            firstMass[first, default: 0] += weights[text]! / total
            // Type evidence: each internal adjacency is counted once per vocabulary spelling.
            // Source frequency weights are priors; they are not sentence-transition counts.
            for (a, b) in zip(characters, characters.dropFirst()) {
                counts[characterIDs[a]!, default: [:]][characterIDs[b]!, default: 0] += 1
            }
        }
        let histories = counts.mapValues { observed in
            let observed = observed.filter { firstMass[$0.key] != nil }
            let total = observed.keys.sorted().reduce(0.0) { $0 + observed[$1]! }
            let denominator = total + Double(observed.count)
            let backoff = denominator > 0 ? Double(observed.count) / denominator : 1
            // Factor P(word | first character) out of the context distribution. The
            // resulting word distribution remains normalized without scanning the lexicon.
            let deltas = Dictionary(uniqueKeysWithValues: observed.map { character, count in
                    (character, -log2(backoff + count / denominator / firstMass[character, default: unknownC]))
                })
            return History(backoffCost: -log2(backoff), observedCosts: deltas)
        }
        contextBackoff = (0...characters.count).map { histories[$0]?.backoffCost ?? 0 }
        var transitions: [UInt64: Double] = [:]
        transitions.reserveCapacity(histories.values.reduce(0) { $0 + $1.observedCosts.count })
        for (previous, history) in histories {
            for (next, cost) in history.observedCosts {
                transitions[UInt64(previous) << 32 | UInt64(next)] = cost
            }
        }
        self.transitions = transitions
        let switchProbability = RankingCalibration.switchProbability
        languageCosts = [-log2(1 - switchProbability), -log2(switchProbability)]
        unknownCosts = (0...characters.count).map { character in
            let backoff = histories[character]?.backoffCost ?? 0
            return -log2((1 - switchProbability) * exp2(-backoff) * unknownC + switchProbability * unknownE)
        }
    }

    func contextIdentity(for token: Int) -> Int { token == 0 ? 0 : (token < englishLimit ? 1 : lastCharacters[token] + 1) }

    @inline(__always)
    func cost(token: Int, after previous: Int = 0) -> Double {
        guard previous != 0 else { return costs[token] }
        let previousEnglish = previous < englishLimit
        let switchProbability = RankingCalibration.switchProbability
        if token == 0 {
            if !previousEnglish { return unknownCosts[lastCharacters[previous]] }
            let chineseMass = previousEnglish ? switchProbability : 1 - switchProbability
            return -log2(chineseMass * chineseUnknown + (1 - chineseMass) * englishUnknown)
        }
        let sameLanguage = previousEnglish == (token < englishLimit)
        let unigram = costs[token] - 1 // Remove the uniform BOS language prior.
        let languageCost = languageCosts[sameLanguage ? 0 : 1]
        guard sameLanguage, !previousEnglish else {
            return unigram + languageCost
        }
        let previousCharacter = lastCharacters[previous]
        let pair = UInt64(previousCharacter) << 32 | UInt64(firstCharacters[token])
        return unigram + languageCost + (transitions[pair] ?? contextBackoff[previousCharacter])
    }

    /// Decode conditionally on the known input boundary. Vocabulary phrase ends are not
    /// sentence/EOS observations, so direct/composed/prefix paths share a neutral endpoint.
    static let terminalCost = 0.0
}

/// A finite geometric truncation channel, normalized over the word's nonempty prefixes.
/// Each omitted source letter halves likelihood; exact/completed matches share this model.
enum SpellingChannel {
    private static let offsets = (1...64).map { 1 + log2(1 - exp2(-Double($0))) }
    static func cost(fullLength: Int, typedLength: Int) -> Double {
        precondition(fullLength > 0 && fullLength <= 64 && typedLength > 0 && typedLength <= fullLength)
        return Double(fullLength - typedLength) + offsets[fullLength - 1]
    }

    static func fullCost(length: Int, abbreviatableSyllables: Int) -> Double {
        cost(fullLength: length, typedLength: length) + (abbreviatableSyllables > 0 ? 1 : 0)
    }

    static func abbreviationCost(variants: Int) -> Double { 1 + log2(Double(variants)) }
}
