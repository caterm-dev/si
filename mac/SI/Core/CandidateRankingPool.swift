import Foundation

/// Shared immutable candidate evidence for an app request or a controlled offline query.
/// The pool is built from the dictionary engine's emitted candidates before experimental ordering.
public struct CandidateRankingPool: Sendable {
    private struct LM: Sendable {
        let bits: Double
        let oovs: Int
        let count: Int

        init(_ score: (bits: Double, oovs: Int, count: Int)) {
            bits = score.bits
            oovs = score.oovs
            count = score.count
        }
    }

    private struct Row: Sendable {
        let candidate: InputCandidate
        let tokens: [RankingToken]
        let chinese: LM?
        let english: LM?
        let chineseCount: Int
        let englishCount: Int
        let chineseFrequency: Double
        let englishFrequency: Double

        var baseScore: Double { candidate.presentationScore ?? candidate.rankingScore }
    }

    public struct Features: Encodable, Sendable {
        public let identity: String
        public let text: String
        public let language: String
        public let values: [String: Double]
        public let relative: [String: Relative]
    }

    public struct Relative: Encodable, Sendable {
        public let rank: Int
        public let deltaFromBest: Double
        public let deltaFromMean: Double
        public let zScore: Double
    }

    private let rows: [Row]
    private let model: KenLMModel?

    public init(candidates: [InputCandidate], model: KenLMModel?, context: [String] = [],
                scoreEnglish: Bool = false) {
        self.model = model
        var scorer = model.map(KenLMScorer.init(model:))
        // Prepare the prefix once. Each candidate receives an independent value copy.
        let chineseState = scorer?.state(after: context)
        rows = candidates.map { candidate in
            let tokens = candidate.isUserPhrase || candidate.hasLiteralSegments || candidate.isApplicationVocabulary
                || candidate.isPunctuation ? [] : candidate.rankingTokens
            let chinese = tokens.filter { $0.language == .simplifiedChinese }
            let english = tokens.filter { $0.language == .english }
            let zh = chinese.isEmpty ? nil : chineseState.flatMap {
                scorer?.score(tokens, language: .simplifiedChinese, startingAt: $0).map(LM.init)
            }
            let en = !scoreEnglish || english.isEmpty ? nil : scorer?.score(tokens, language: .english).map(LM.init)
            return Row(candidate: candidate, tokens: tokens, chinese: zh, english: en, chineseCount: chinese.count,
                       englishCount: english.count,
                       chineseFrequency: chinese.reduce(0) { $0 + $1.frequencyBits },
                       englishFrequency: english.reduce(0) { $0 + $1.frequencyBits })
        }
    }

    /// Offline insertion-only ablation is explicit. An enabled model with zero weights uses the
    /// same lexical scores as the legacy engine, including when the coverage toggle is independent.
    public func ranked(using configuration: RankingExperiment, insertionOnly: Bool = false) -> [InputCandidate] {
        let active = configuration.isActive && configuration.model === model && !insertionOnly
        guard active || insertionOnly || configuration.fullCoverageFirst || configuration.adjustsEnglishInsertion
        else { return rows.map(\.candidate) }
        return rows.map { row in
            let score = adjusted(row, configuration: configuration, active: active, insertionOnly: insertionOnly)
            return (row.candidate, score.bits, score.oovRatio)
        }.sorted {
            precedes($0.0, $0.1, $1.0, $1.1, configuration: configuration)
        }.map { candidate, score, ratio in
            guard !candidate.isLiteral else { return candidate }
            let ranked = candidate.withPresentationScore(score, remembered: candidate.isRememberedChoice)
            return ratio.map { ranked.withLMOOVRatio($0) } ?? ranked
        }
    }

    public func first(using configuration: RankingExperiment, insertionOnly: Bool = false) -> InputCandidate? {
        let active = configuration.isActive && configuration.model === model && !insertionOnly
        guard active || insertionOnly || configuration.fullCoverageFirst || configuration.adjustsEnglishInsertion
        else { return rows.first?.candidate }
        var best: (InputCandidate, Double)?
        for row in rows {
            let score = adjusted(row, configuration: configuration, active: active, insertionOnly: insertionOnly).bits
            if let previous = best, !precedes(row.candidate, score, previous.0, previous.1, configuration: configuration) {
                continue
            }
            best = (row.candidate, score)
        }
        return best?.0
    }

    private func precedes(_ a: InputCandidate, _ aScore: Double, _ b: InputCandidate, _ bScore: Double,
                          configuration: RankingExperiment) -> Bool {
        if a.isLiteral != b.isLiteral { return !a.isLiteral }
        if a.isPreferred != b.isPreferred { return a.isPreferred }
        if a.isRememberedChoice != b.isRememberedChoice { return a.isRememberedChoice }
        if let order = configuration.coverageOrder(a, b) { return order }
        if aScore != bScore { return aScore > bScore }
        return a.id < b.id
    }

    private func adjusted(_ row: Row, configuration: RankingExperiment, active: Bool,
                          insertionOnly: Bool) -> (bits: Double, oovRatio: Double?) {
        var score = row.baseScore
        if configuration.adjustsEnglishInsertion, row.englishCount > 0 {
            let delta = RankingExperiment.defaultEnglishWordInsertionBits - configuration.englishWordInsertionBits
            score += delta * Double(row.englishCount)
        }
        var oovs = 0
        var count = 0
        let insertionDelta = 20 / log(2.0) - configuration.wordInsertionBits
        if insertionOnly {
            score += insertionDelta * Double(row.chineseCount)
        } else if active {
            if configuration.languageModelWeight != 0, let zh = row.chinese {
                score += configuration.languageModelWeight * zh.bits
                    + (configuration.frequencyWeight - 1) * row.chineseFrequency
                    + insertionDelta * Double(zh.count)
                oovs += zh.oovs
                count += zh.count
            }
            if configuration.englishLanguageModelWeight != 0, let en = row.english {
                score += configuration.englishLanguageModelWeight * en.bits
                    + (configuration.frequencyWeight - 1) * row.englishFrequency
                oovs += en.oovs
                count += en.count
            }
        }
        return (score, count == 0 ? nil : Double(oovs) / Double(count))
    }

    public func features(input: String) -> [Features] {
        let total = CandidateScoring.coverageUnitCount(in: input)
        let isWord = rows.contains { row in
            Self.fullMatch(row.candidate) && row.candidate.lexicalTokenCount == 1 && !row.tokens.isEmpty
        }
        let absolute = rows.map { row -> [String: Double] in
            let candidate = row.candidate
            var values = [
                "is_full_match": Self.fullMatch(candidate) ? 1.0 : 0.0,
                "is_full_coverage": candidate.isPartial ? 0.0 : 1.0,
                "has_completion": candidate.hasCompletion ? 1.0 : 0.0,
                "input_is_dictionary_word": isWord ? 1.0 : 0.0,
                "base_score": row.baseScore,
                "language_zh": candidate.language == .simplifiedChinese && !candidate.isMixed ? 1.0 : 0.0,
                "language_en": candidate.language == .english ? 1.0 : 0.0,
                "language_mixed": candidate.isMixed ? 1.0 : 0.0,
                "language_literal": candidate.isLiteral ? 1.0 : 0.0
            ]
            if total > 0 {
                let consumed = candidate.consumedInputCount.map {
                    CandidateScoring.coverageUnitCount(in: String(input.prefix($0)))
                } ?? total
                values["coverage"] = Double(consumed) / Double(total)
            }
            if !row.tokens.isEmpty {
                let lengths = row.tokens.map { $0.text.unicodeScalars.count }
                let count = Double(lengths.count)
                values["num_words"] = count
                values["avg_word_len"] = Double(lengths.reduce(0, +)) / count
                values["num_single_char_words"] = Double(lengths.filter { $0 == 1 }.count)
                values["log_freq_sum"] = row.chineseFrequency + row.englishFrequency
                values["log_freq_min"] = row.tokens.map(\.frequencyBits).min()
            }
            let scores = [row.chinese, row.english].compactMap { $0 }
            if !scores.isEmpty {
                let count = Double(scores.reduce(0) { $0 + $1.count })
                let bits = scores.reduce(0.0) { $0 + $1.bits }
                values["lm_bits"] = bits
                values["lm_bits_per_word"] = bits / count
                values["lm_oov_ratio"] = Double(scores.reduce(0) { $0 + $1.oovs }) / count
            }
            return values
        }
        var relative = Array(repeating: [String: Relative](), count: rows.count)
        let groups = Dictionary(grouping: rows.indices) { rows[$0].candidate.consumedInputCount }
        for indices in groups.values {
            for name in Set(indices.flatMap { absolute[$0].keys }) {
                var values: [(Int, Double)] = []
                for index in indices {
                    if let value = absolute[index][name] { values.append((index, value)) }
                }
                values.sort { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
                guard let best = values.first?.1 else { continue }
                let mean = values.reduce(0.0) { $0 + $1.1 } / Double(values.count)
                let deviation = sqrt(values.reduce(0.0) { $0 + pow($1.1 - mean, 2) } / Double(values.count))
                var rank = 1
                for (offset, pair) in values.enumerated() {
                    if offset > 0 && pair.1 != values[offset - 1].1 { rank = offset + 1 }
                    relative[pair.0][name] = Relative(rank: rank, deltaFromBest: pair.1 - best,
                        deltaFromMean: pair.1 - mean, zScore: deviation == 0 ? 0 : (pair.1 - mean) / deviation)
                }
            }
        }
        return rows.indices.map { index in
            let candidate = rows[index].candidate
            return Features(identity: candidate.id, text: candidate.text,
                language: candidate.isMixed ? "zh-Hans+en" : candidate.language?.rawValue ?? "literal",
                values: absolute[index], relative: relative[index])
        }
    }

    private static func fullMatch(_ candidate: InputCandidate) -> Bool {
        !candidate.isPartial && !candidate.isLiteral && !candidate.hasLiteralSegments
            && !candidate.hasCompletion && !candidate.isUserPhrase && !candidate.isApplicationVocabulary
            && !candidate.isPunctuation
    }
}
