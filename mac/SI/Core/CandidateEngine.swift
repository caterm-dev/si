import Foundation

public struct CandidateEngine: Sendable {
    private let providers: [any CandidateProvider]?
    private struct PrefixBoundary: Hashable {
        let sourceCount: Int
        let languages: Int
        let outputBytes: [UInt8]

        init(_ candidate: InputCandidate) {
            sourceCount = candidate.consumedInputCount ?? 0
            languages = candidate.isMixed ? 3 : candidate.language == .english ? 2 : 1
            outputBytes = Array(candidate.text.utf8)
        }

        init(sourceCount: Int, languages: Int, outputBytes: [UInt8]) {
            self.sourceCount = sourceCount
            self.languages = languages
            self.outputBytes = outputBytes
        }
    }

    public init(providers: [any CandidateProvider]? = nil) {
        self.providers = providers
        // Creating a deferred client session must not load dictionaries on the main actor.
        // The shared immutable resources initialize when its worker first generates candidates.
    }

    public func candidates(for input: String, languages: Set<InputLanguage>,
                           learning: LearningProfile = LearningProfile(), dictionary: UserDictionary = UserDictionary(),
                           now: Date = .now, context: CandidateContext? = nil,
                           includesConfirmationEvidence: Bool = false,
                           applicationMemory: ApplicationMemorySnapshot = .empty) -> [InputCandidate] {
        guard !input.isEmpty else { return [] }
        var generated: [InputCandidate]
        if let providers {
            generated = providers.filter { $0.requiredLanguages.isSubset(of: languages) }.flatMap { $0.candidates(for: input) }
                + dictionary.candidates(for: input, languages: languages)
        } else {
            generated = (languages.contains(.english) ? EnglishCandidateProvider().candidates(for: input) : [])
                + PinyinDecoder.standard.compositionCandidates(for: input, languages: languages, dictionary: dictionary,
                                                               learning: learning, now: now, context: context,
                                                               includesConfirmationEvidence: includesConfirmationEvidence)
        }
        generated += punctuationCandidates(for: input, languages: languages, learning: learning, dictionary: dictionary,
                                            now: now, context: context, applicationMemory: applicationMemory, preview: false)
        let identities = Set(generated.map(\.id))
        let saved = applicationMemory.vocabularyCandidates(for: input, languages: languages, now: now)
            .filter { !identities.contains($0.id) }
        let merged = merge(generated + saved,
                           input: input, languages: languages, learning: learning, dictionary: dictionary,
                           now: now, context: context)
        return attachHistory(applicationMemory.historyCandidates(for: input, languages: languages, now: now), to: merged)
    }

    /// Provisional hints share the normal lookup/lattice/merge, with smaller lexical budgets.
    /// Custom providers have no bounded-preview contract, so they run only in the final search.
    func previewCandidates(for input: String, languages: Set<InputLanguage>, learning: LearningProfile,
                           dictionary: UserDictionary, now: Date, context: CandidateContext?,
                           applicationMemory: ApplicationMemorySnapshot = .empty) -> [InputCandidate] {
        guard !input.isEmpty else { return [] }
        guard providers == nil else {
            return punctuationCandidates(for: input, languages: languages, learning: learning, dictionary: dictionary,
                                         now: now, context: context, applicationMemory: applicationMemory, preview: true)
                + [InputCandidate(text: input, language: nil, score: 0)]
        }
        var generated: [InputCandidate] = []
        if languages.contains(.english) {
            let key = input.lowercased()
            let style = EnglishLexicon.CaseStyle(input: input)
            generated = EnglishLexicon.previewMatches(for: key).map {
                InputCandidate(text: $0.text(for: style), language: .english,
                               score: Int(-$0.cost(typedLength: key.utf8.count) * CandidateScoring.pointsPerBit),
                               rankingScore: -$0.cost(typedLength: key.utf8.count) * CandidateScoring.pointsPerBit,
                               hasCompletion: $0.text.lowercased() != key, lexicalTokenCount: 1)
                    .withWordContext(.english)
            }
        }
        generated += PinyinDecoder.standard.compositionCandidates(for: input, languages: languages,
            dictionary: dictionary, learning: learning, now: now, context: context, preview: true)
        generated += punctuationCandidates(for: input, languages: languages, learning: learning, dictionary: dictionary,
                                            now: now, context: context, applicationMemory: applicationMemory, preview: true)
        let identities = Set(generated.map(\.id))
        let saved = applicationMemory.vocabularyCandidates(for: input, languages: languages, now: now)
            .filter { !identities.contains($0.id) }
        let merged = merge(generated + saved,
                           input: input, languages: languages, learning: learning, dictionary: dictionary,
                           now: now, context: context)
        return attachHistory(applicationMemory.historyCandidates(for: input, languages: languages, now: now), to: merged)
    }

    private func punctuationCandidates(for input: String, languages: Set<InputLanguage>, learning: LearningProfile,
                                       dictionary: UserDictionary, now: Date, context: CandidateContext?,
                                       applicationMemory: ApplicationMemorySnapshot, preview: Bool) -> [InputCandidate] {
        guard let punctuation = PunctuationCandidates.split(input),
              !PunctuationCandidates.hasRecognizedSuffix(punctuation.prefix) else { return [] }
        let prefixes: [InputCandidate]
        if punctuation.prefix.isEmpty {
            prefixes = [InputCandidate(text: "", language: nil, score: 0)]
        } else if preview {
            prefixes = previewCandidates(for: punctuation.prefix, languages: languages, learning: learning,
                                         dictionary: dictionary, now: now, context: context, applicationMemory: applicationMemory)
        } else {
            prefixes = candidates(for: punctuation.prefix, languages: languages, learning: learning, dictionary: dictionary,
                                  now: now, context: context, applicationMemory: applicationMemory)
        }
        return PunctuationCandidates.candidates(symbol: punctuation.symbol, prefixes: prefixes, languages: languages) {
            learning.rankingScore(for: $0, input: punctuation.prefix, now: now, context: context)
        }
    }

    private func attachHistory(_ history: [InputCandidate], to candidates: [InputCandidate]) -> [InputCandidate] {
        guard !history.isEmpty else { return candidates }
        // Keep the engine's first two whole choices, then expose explicitly confirmed history suggestions.
        let whole = candidates.indices.filter { !candidates[$0].isLiteral && !candidates[$0].isPartial }
        let insertion = whole.prefix(2).last.map { $0 + 1 } ?? 0
        var result = candidates
        result.insert(contentsOf: history, at: insertion)
        return result
    }

    private func merge(_ generated: [InputCandidate], input: String, languages: Set<InputLanguage>,
                       learning: LearningProfile, dictionary: UserDictionary, now: Date,
                       context: CandidateContext?) -> [InputCandidate] {
        // Personal entries may share text with a built-in candidate. Keep the stronger derivation.
        var best: [String: (candidate: InputCandidate, score: Double)] = [:]
        best.reserveCapacity(generated.count)
        var remainingCandidates = continuationCache(for: generated, input: input, languages: languages,
                                                    dictionary: dictionary, now: now)
        let supportedPrefixes = supportedPrefixScores(generated, inputCount: input.count, languages: languages)
        for candidate in generated {
            var candidate = candidate
            guard let language = candidate.language, languages.contains(language), !candidate.text.isEmpty else { continue }
            if candidate.isMixed && (language != .simplifiedChinese || !languages.contains(.english)) { continue }
            if let count = candidate.consumedInputCount, count <= 0 || count >= input.count { continue }
            if candidate.isPartial, let completeScore = supportedPrefixes[PrefixBoundary(candidate)] {
                candidate.accountForRemainingInput(score: completeScore - candidate.rankingScore
                    - CandidateScoring.partialConfirmationCost)
            } else if let count = candidate.consumedInputCount {
                let tails: [InputCandidate]
                if let cached = remainingCandidates[count] { tails = cached }
                else {
                    tails = continuations(for: String(input.dropFirst(count)), languages: languages,
                                          dictionary: dictionary, now: now)
                    remainingCandidates[count] = tails
                }
                let remaining = tails.map { $0.rankingScore + CandidateWordContext.joining(candidate, to: $0) }.max()
                    ?? -(CandidateScoring.wordCost(weight: 1) + Double(input.dropFirst(count).utf8.count) * 8)
                candidate.accountForRemainingInput(score: remaining - CandidateScoring.partialConfirmationCost)
            }
            let spelling = candidate.consumedInputCount.map { String(input.prefix($0)) } ?? input
            let score = learning.rankingScore(for: candidate, input: spelling, now: now, context: context)
            if let previous = best[candidate.id],
               (previous.candidate.isPreferred && !candidate.isPreferred)
                || (previous.candidate.isPreferred == candidate.isPreferred
                    && (previous.score > score || (previous.score == score && !candidate.isUserPhrase))) {
                best[candidate.id]?.candidate.retainLexicalEvidence(from: candidate)
                continue
            }
            if let previous = best[candidate.id] { candidate.retainLexicalEvidence(from: previous.candidate) }
            best[candidate.id] = (candidate, score)
        }
        let merged = best.values
            .sorted {
                // Whole and prefix candidates share the effective-score objective.
                if $0.candidate.isPreferred != $1.candidate.isPreferred { return $0.candidate.isPreferred }
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.candidate.id < $1.candidate.id
            }
            .map(\.candidate)
        // Never drop an enabled language's candidates because another language matches.
        // Literal input stays available even with all language providers disabled.
        return merged + [InputCandidate(text: input, language: nil, score: 0)]
    }

    /// A known complete path is the strongest evidence for a prefix's compatible continuation.
    /// Source and UTF-8 boundaries must both agree; a matching text prefix alone is insufficient.
    private func supportedPrefixScores(_ generated: [InputCandidate], inputCount: Int,
                                       languages: Set<InputLanguage>) -> [PrefixBoundary: Double] {
        var scores: [PrefixBoundary: Double] = [:]
        for candidate in generated where !candidate.isPartial && !candidate.isLiteral && !candidate.isUserPhrase
            && !candidate.hasLiteralSegments && !candidate.isHistory
            && candidate.language.map(languages.contains) == true
            && (!candidate.isMixed || languages.contains(.english)) {
            var trace = candidate.sourceTrace
            while let node = trace {
                let spacedEnglish = candidate.language == .english && !candidate.isUserPhrase && !candidate.hasLiteralSegments
                let outputEnd = spacedEnglish ? node.boundary.outputByteCount : node.rawOutputByteCount
                let wordStart = outputEnd - node.word.utf8.count
                let boundaries = [ConfirmationBoundary(sourceCount: node.boundary.sourceCount, outputByteCount: outputEnd)]
                    + node.interiorBoundaries.map {
                        ConfirmationBoundary(sourceCount: $0.sourceCount, outputByteCount: wordStart + $0.outputByteCount)
                    }
                for boundary in boundaries where boundary.sourceCount > 0 && boundary.sourceCount < inputCount
                    && boundary.outputByteCount > 0 && boundary.outputByteCount < candidate.text.utf8.count {
                    let key = PrefixBoundary(sourceCount: boundary.sourceCount, languages: node.languages,
                        outputBytes: Array(candidate.text.utf8.prefix(boundary.outputByteCount)))
                    scores[key] = max(scores[key] ?? -.infinity, candidate.rankingScore)
                }
                trace = node.previous
            }
        }
        return scores
    }

    /// Fill gaps by decoding short bridges into existing suffix paths, reusing identical bridge text.
    /// At most three nearby splice boundaries and two tail alternatives per bridge are considered.
    private func continuationCache(for generated: [InputCandidate], input: String, languages: Set<InputLanguage>,
                                   dictionary: UserDictionary, now: Date) -> [Int: [InputCandidate]] {
        var cache = CandidateContinuation.projections(of: generated, inputCount: input.count, languages: languages)
        guard providers == nil else { return cache }
        let source = Array(input)
        let boundaries = Set(generated.compactMap(\.consumedInputCount).filter { $0 > 0 && $0 < source.count })
        var queries: [String: [InputCandidate]] = [:]
        func lookup(_ spelling: String) -> [InputCandidate] {
            if let result = queries[spelling] { return result }
            let result = CandidateContinuation.bounded(continuations(for: spelling, languages: languages,
                                                                    dictionary: dictionary, now: now))
            queries[spelling] = result
            return result
        }
        for start in boundaries.sorted(by: >) where cache[start] == nil {
            var ends = Array(cache.keys.filter { $0 > start && $0 - start <= 12 && cache[$0]?.isEmpty == false }.sorted().prefix(3))
            if source.count - start <= 12 { ends.append(source.count) }
            // Without a nearby retained suffix, a long unsupported tail uses the explicit unknown-span model.
            // Do not turn every prefix into another whole-input lattice search.
            if ends.isEmpty { cache[start] = []; continue }
            var candidates: [InputCandidate] = []
            for end in ends {
                let bridge = lookup(String(source[start..<end]))
                if end == source.count { candidates += bridge; continue }
                for first in bridge where !first.hasCompletion {
                    let joined = (cache[end] ?? []).compactMap { CandidateContinuation.joining(first, $0) }
                        .sorted { $0.rankingScore == $1.rankingScore ? $0.id < $1.id : $0.rankingScore > $1.rankingScore }
                    candidates += joined.prefix(2)
                }
            }
            if candidates.isEmpty && source.count - start <= 12 { candidates = lookup(String(source[start...])) }
            cache[start] = CandidateContinuation.bounded(candidates)
        }
        return cache
    }

    /// Unsupported prefixes use a bounded full suffix decode cached once per source boundary.
    /// Its BOS costs are replaced with the actual prefix/suffix lexical boundary during comparison.
    /// Future preferences are excluded: only the actually consumed spelling can personalize a prefix.
    private func continuations(for input: String, languages: Set<InputLanguage>,
                               dictionary: UserDictionary, now: Date) -> [InputCandidate] {
        let candidates: [InputCandidate]
        if let providers {
            candidates = providers.filter { $0.requiredLanguages.isSubset(of: languages) }
                .flatMap { $0.candidates(for: input) } + dictionary.candidates(for: input, languages: languages)
        } else {
            let key = input.lowercased()
            let style = EnglishLexicon.CaseStyle(input: input)
            let english: [InputCandidate] = languages.contains(.english) ? EnglishLexicon.previewMatches(for: key).map { entry in
                let score = -entry.cost(typedLength: key.utf8.count) * CandidateScoring.pointsPerBit
                return InputCandidate(text: entry.text(for: style), language: .english, score: Int(score),
                    rankingScore: score, hasCompletion: entry.length != key.utf8.count, lexicalTokenCount: 1)
                    .withWordContext(.english)
            } : []
            candidates = english + PinyinDecoder.standard.continuationCandidates(for: input, languages: languages,
                dictionary: dictionary, now: now)
        }
        return candidates.filter {
            !$0.isPartial && !$0.isLiteral && !$0.isHistory && !$0.text.isEmpty
                && $0.language.map(languages.contains) == true
                && (!$0.isMixed || ($0.language == .simplifiedChinese && languages.contains(.english)))
        }
    }
}
