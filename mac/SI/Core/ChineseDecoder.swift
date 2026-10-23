import Foundation

/// Swift adaptation of MSIME's full-pinyin dictionary and word-lattice pipeline.
/// The source revision, GPL attribution and local data changes live in Data/Chinese/MSIME.
/// Mutable search state belongs to a request; the decoder retains only immutable resources.
struct ChineseDecoder: Sendable {
    static let standard = ChineseDecoder(lexicon: .standard)
    private static let beam = 32
    private static let spanLimit = 32
    private static let maximumWordSyllables = 7
    private static let finalPaths = 6
    private static let bitsPerNat = 1 / log(2.0)
    private let lexicon: ChineseLexicon

    init(lexicon: ChineseLexicon) { self.lexicon = lexicon }

    private struct Edge {
        let end: Int
        let sourceStart: Int
        let sourceEnd: Int
        let text: String
        let score: Double
        let personal: Bool
        let tokenBonus: Double
        let letters: Int
    }

    private struct Path {
        var arrival = 0
        var sourceEnd = 0
        var text = ""
        var words: [String] = []
        /// Keep natural-log arithmetic through search and trigram rescoring.
        /// Conversion to SI's bit-based preference units happens at ranking boundaries.
        var score = -CandidateScoring.initialLanguageCost * log(2.0)
        var personal = false
        var tokenSum = 0.0
        var letters = 0
        var boundaries: [ConfirmationBoundary] = []
        var tokenBonus: Double { personal || letters == 0 ? 0 : min(32, tokenSum / Double(letters)) }
    }

    func candidates(for source: String, dictionary: UserDictionary, learning: LearningProfile,
                    now: Date, context: CandidateContext?, includesPartials: Bool,
                    includesConfirmationEvidence: Bool, preview: Bool) -> [InputCandidate] {
        guard let input = PinyinInput(source) else { return [] }
        // Saved codes augment the Chinese lattice; they must not change or erase the
        // standard dictionary reading (for example a saved nihao code versus ni'hao).
        let literal = ChineseSyllables.primary(input)
        let alias = ChineseSpellingAliases.readings(input).first
        let primary = alias ?? (literal.isEmpty ? nil : ChineseReading(syllables: literal))
        var cuts = primary.map { [$0] } ?? []
        // Ambiguous consonant boundaries must compete in sentence search too:
        // wo/xian/gan/zhao and wo/xiang/an/zhao have equal spelling evidence.
        var sentenceReadings = cuts
        if let primary, !primary.isCorrected,
           primary.syllables.allSatisfy(ChineseSyllables.complete.contains) {
            var seen: Set<[String]> = [primary.syllables.map(ChineseSyllables.canonical)]
            for cut in ChineseSyllables.alternatives(input, minimumOnly: true)
                where cut.count == primary.syllables.count && sentenceReadings.count < 32 {
                if seen.insert(cut.map(ChineseSyllables.canonical)).inserted {
                    sentenceReadings.append(ChineseReading(syllables: cut))
                }
            }
        }
        // Broader full-key lookup alternatives remain limited to short unseparated
        // input. Sentence cuts above use only equally short complete segmentations;
        // additional corrected alias readings still belong to optional autocorrection.
        if input.separators.isEmpty, let primary, primary.syllables.count <= 4,
           primary.syllables.allSatisfy(ChineseSyllables.complete.contains) {
            var seen: Set<[String]> = [primary.syllables.map(ChineseSyllables.canonical)]
            for cut in ChineseSyllables.alternatives(input) {
                let reading = ChineseReading(syllables: cut)
                if seen.insert(cut.map(ChineseSyllables.canonical)).inserted { cuts.append(reading) }
            }
        }
        let alternativeRows = lexicon.exactAlternatives(cuts.dropFirst().map(\.syllables))
        let ranking = learning.ranking(for: source, now: now, context: context)
        var choices: [InputCandidate] = []
        var prefixes: [InputCandidate] = []
        for (cutIndex, reading) in cuts.enumerated() {
            let cut = reading.syllables
            let offsets = reading.offsets
            let normalized = cut.map(ChineseSyllables.canonical)
            // Alternative cuts contribute full-key dictionary rows. Re-running sentence
            // search on each alternative would change MSIME's primary sentence objective.
            let direct = cutIndex == 0 ? lexicon.matches(normalized, limit: preview ? 32 : nil)
                : alternativeRows.filter { $0.reading == normalized }
            var lexical = direct.map { (row: $0, typed: normalized) }
            if cutIndex == 0 {
                for split in ChineseLookupReadings.splitInitials(reading, input: input) {
                    lexical += lexicon.matches(split.syllables, limit: preview ? 32 : nil)
                        .map { (row: $0, typed: split.syllables.map(ChineseSyllables.canonical)) }
                }
                lexical += lexicon.completions(normalized).map { (row: $0, typed: normalized) }
            }
            for (row, typed) in lexical {
                let exact = row.reading == typed
                let completion = Self.completes(row.reading, typed: typed)
                let score = wordScore(row, typed: typed)
                choices.append(InputCandidate(text: row.text, language: .simplifiedChinese,
                    score: Int(score), rankingScore: score,
                    hasCompletion: completion, lexicalTokenCount: exact || completion ? 1 : nil))
            }
            guard cutIndex == 0 else { continue }
            if includesPartials, cut.count > 1 {
                var seenPrefixes = Set<[String]>()
                for sentenceReading in sentenceReadings {
                    for end in 1..<sentenceReading.syllables.count {
                        let offsets = sentenceReading.offsets
                        let span = Array(sentenceReading.syllables[..<end])
                        let prefixReading = ChineseReading(syllables: span,
                            offsets: Array(offsets[...end]), isCorrected: sentenceReading.isCorrected)
                        let prefixReadings = [prefixReading] + ChineseLookupReadings.splitInitials(prefixReading, input: input)
                        for prefix in prefixReadings {
                            guard seenPrefixes.insert(prefix.syllables).inserted else { continue }
                            for row in lexicon.matches(prefix.syllables, limit: preview ? 16 : nil) {
                                let full = row.reading == prefix.syllables.map(ChineseSyllables.canonical)
                                let score = wordScore(row, typed: prefix.syllables)
                                prefixes.append(InputCandidate(text: row.text, language: .simplifiedChinese,
                                    score: Int(score),
                                    consumedInputCount: input.rawBoundaries[offsets[end]],
                                    rankingScore: score,
                                    hasCompletion: Self.completes(row.reading, typed: prefix.syllables),
                                    lexicalTokenCount: full ? 1 : nil))
                            }
                        }
                    }
                }
            }

            // Equal-length complete cuts share one bounded word-context search.
            if cut.count >= 2,
               normalized.allSatisfy(ChineseSyllables.complete.contains) || dictionary.phraseCount > 0 || includesPartials {
                let paths = decode(normalized, offsets: offsets, input: input, source: source,
                                   dictionary: dictionary, learning: learning, now: now, context: context,
                                   evidence: includesConfirmationEvidence && !preview && !reading.isCorrected,
                                   includesPartials: includesPartials, prefixes: &prefixes,
                                   alternatives: Array(sentenceReadings.dropFirst()))
                for path in paths {
                    let score = path.score * Self.bitsPerNat
                    let candidate = InputCandidate(text: path.text, language: .simplifiedChinese,
                        score: Int(score), isUserPhrase: path.personal, rankingScore: score,
                        tokenLearningBonus: path.tokenBonus, lexicalTokenCount: path.words.count,
                        confirmationBoundaries: path.personal ? [] : path.boundaries)
                    choices.append(candidate)
                }
            }
            if choices.count + prefixes.count < 8 {
                for fallback in ChineseLookupReadings.sparseFallbacks(reading) {
                    let consumed = input.rawBoundaries[fallback.offsets.last!]
                    for row in lexicon.matches(fallback.syllables, limit: preview ? 32 : nil) {
                        let score = wordScore(row, typed: fallback.syllables)
                        let candidate = InputCandidate(text: row.text, language: .simplifiedChinese,
                            score: Int(score), consumedInputCount: consumed < source.count ? consumed : nil,
                            rankingScore: score, lexicalTokenCount: row.reading == fallback.syllables ? 1 : nil)
                        if candidate.isPartial {
                            if includesPartials { prefixes.append(candidate) }
                        } else {
                            choices.append(candidate)
                        }
                    }
                }
            }
        }
        if dictionary.phraseCount > 0 {
            let pieces = ChineseSyllables.primary(input, personal: dictionary)
            if pieces.count > 1, pieces != (primary?.syllables ?? []),
               pieces.contains(where: { dictionary.phrases(for: $0).contains { $0.language == .simplifiedChinese } }) {
                let reading = ChineseReading(syllables: pieces)
                let paths = decode(pieces.map(ChineseSyllables.canonical), offsets: reading.offsets,
                    input: input, source: source, dictionary: dictionary, learning: learning, now: now,
                    context: context, evidence: false, includesPartials: includesPartials,
                    prefixes: &prefixes, personalOnly: true)
                for path in paths {
                    let score = path.score * Self.bitsPerNat
                    let candidate = InputCandidate(text: path.text, language: .simplifiedChinese,
                        score: Int(score), isUserPhrase: true, rankingScore: score, lexicalTokenCount: path.words.count)
                    choices.append(candidate)
                }
            }
            if includesPartials, input.letters.count > 1 {
                for end in 1...min(input.letters.count - 1, dictionary.maximumCodeLength) {
                    let code = String(input.letters[..<end])
                    for phrase in dictionary.directPhrases(for: code) where phrase.language == .simplifiedChinese
                        && input.respects(phrase.boundaries, from: 0, to: end) {
                        let score = -CandidateScoring.initialLanguageCost
                            - CandidateScoring.personalCost(codeLength: code.count, typedLength: code.count, pinned: phrase.isPinned)
                        prefixes.append(InputCandidate(text: phrase.text, language: .simplifiedChinese,
                            score: Int(score), isUserPhrase: true, consumedInputCount: input.rawBoundaries[end],
                            rankingScore: score, lexicalTokenCount: 1))
                    }
                }
            }
        }
        for candidate in dictionary.candidates(for: source, languages: [.simplifiedChinese]).sorted(by: { $0.id < $1.id }) {
            choices.append(candidate)
        }
        var best: [String: InputCandidate] = [:]
        for var candidate in choices {
            if let previous = best[candidate.id] {
                let better = candidate.isPreferred != previous.isPreferred ? candidate.isPreferred
                    : ranking.score(candidate) > ranking.score(previous)
                        || (ranking.score(candidate) == ranking.score(previous) && candidate.isUserPhrase && !previous.isUserPhrase)
                var retained = better ? candidate : previous
                retained.retainLexicalEvidence(from: better ? previous : candidate)
                candidate = retained
            }
            best[candidate.id] = candidate
        }
        let ordered = best.values.sorted {
            if $0.isPreferred != $1.isPreferred { return $0.isPreferred }
            let left = ranking.score($0), right = ranking.score($1)
            return left == right ? $0.id < $1.id : left > right
        }
        guard includesPartials else { return ordered }
        var prefixBest: [String: (candidate: InputCandidate, score: Double)] = [:]
        for var candidate in prefixes {
            let score = learning.rankingScore(for: candidate, input: String(source.prefix(candidate.consumedInputCount!)),
                                              now: now, context: context)
            if let previous = prefixBest[candidate.id] {
                if previous.score >= score {
                    prefixBest[candidate.id]?.candidate.retainLexicalEvidence(from: candidate)
                    continue
                }
                candidate.retainLexicalEvidence(from: previous.candidate)
            }
            prefixBest[candidate.id] = (candidate, score)
        }
        let rankedPrefixes = prefixBest.values.sorted {
            if $0.candidate.consumedInputCount != $1.candidate.consumedInputCount {
                return $0.candidate.consumedInputCount! > $1.candidate.consumedInputCount!
            }
            return $0.score == $1.score ? $0.candidate.id < $1.candidate.id : $0.score > $1.score
        }.map(\.candidate)
        var lexicalCounts: [Int: Int] = [:]
        var composedCounts: [Int: Int] = [:]
        let partials = rankedPrefixes.filter { candidate in
            guard let consumed = candidate.consumedInputCount else { return false }
            if candidate.isUserPhrase { return true }
            if candidate.lexicalTokenCount == 1 {
                guard lexicalCounts[consumed, default: 0] < 24 else { return false }
                lexicalCounts[consumed, default: 0] += 1
            } else {
                guard composedCounts[consumed, default: 0] < 2 else { return false }
                composedCounts[consumed, default: 0] += 1
            }
            return true
        }
        return ordered + partials
    }

    private func decode(_ syllables: [String], offsets: [Int], input: PinyinInput, source: String,
                        dictionary: UserDictionary, learning: LearningProfile, now: Date,
                        context: CandidateContext?, evidence: Bool, includesPartials: Bool,
                        prefixes: inout [InputCandidate], personalOnly: Bool = false,
                        alternatives: [ChineseReading] = []) -> [Path] {
        let count = syllables.count
        var graph = Array(repeating: [Edge](), count: count)
        var lookup: [String: [DictionaryLexeme]] = [:]
        struct Span: Hashable {
            let end: Int
            let sourceStart: Int
            let sourceEnd: Int
            let syllables: [String]
        }
        var spans = Array(repeating: Set<Span>(), count: count)
        let readings = [ChineseReading(syllables: syllables, offsets: offsets, isCorrected: false)] + alternatives
        // Columns retain a fixed syllable ordinal. Source offsets keep edges from
        // incompatible cuts from joining, while shared spans are looked up only once.
        for reading in readings {
            let syllables = reading.syllables.map(ChineseSyllables.canonical)
            let offsets = reading.offsets
            for start in 0..<count {
                for end in start + 1...min(count, start + max(Self.maximumWordSyllables, dictionary.maximumCodeLength)) {
                    let span = Array(syllables[start..<end])
                    guard spans[start].insert(Span(end: end, sourceStart: offsets[start], sourceEnd: offsets[end],
                                                   syllables: span)).inserted else { continue }
                    let key = span.joined(separator: "'")
                    let rows: [DictionaryLexeme]
                    if let cached = lookup[key] { rows = cached }
                    else {
                        rows = span.count <= Self.maximumWordSyllables && span.allSatisfy(ChineseSyllables.complete.contains)
                            ? lexicon.exactMatches(span, limit: Self.spanLimit) : []
                        lookup[key] = rows
                    }
                    let spelling = input.rawText(from: offsets[start], to: offsets[end])
                    for row in rows {
                        graph[start].append(Edge(end: end, sourceStart: offsets[start], sourceEnd: offsets[end], text: row.text,
                            score: -log(2.0) * (CandidateScoring.wordCost(weight: row.weight, isChineseCharacter: row.reading.count == 1)
                                + CandidateScoring.chineseSpellingCost(reading: row.reading, typed: span)), personal: false,
                            tokenBonus: learning.tokenBonus(input: spelling, text: row.text, language: .simplifiedChinese, now: now),
                            letters: offsets[end] - offsets[start]))
                    }
                    let code = String(input.letters[offsets[start]..<offsets[end]])
                    for phrase in dictionary.phrases(for: code) where phrase.language == .simplifiedChinese
                        && input.respects(phrase.boundaries, from: offsets[start], to: offsets[end]) {
                        graph[start].append(Edge(end: end, sourceStart: offsets[start], sourceEnd: offsets[end], text: phrase.text,
                            score: -log(2.0) * CandidateScoring.personalCost(codeLength: code.count, typedLength: code.count,
                                                                          pinned: phrase.isPinned), personal: true,
                            tokenBonus: 0, letters: offsets[end] - offsets[start]))
                    }
                }
            }
        }
        let ranking = learning.ranking(for: source, now: now, context: context)
        func candidate(_ path: Path) -> InputCandidate {
            let score = path.score * Self.bitsPerNat
            return InputCandidate(text: path.text, language: .simplifiedChinese, score: Int(score),
                isUserPhrase: path.personal, rankingScore: score, tokenLearningBonus: path.tokenBonus)
        }
        var columns = Array(repeating: ChineseBeam<Path>(limit: Self.beam), count: count + 1)
        var personalColumns = Array(repeating: ChineseBeam<Path>(limit: Self.beam), count: count + 1)
        var prefixColumns = Array(repeating: [Path](), count: count + 1)
        let tokenPreferences = learning.hasTokenPreferences
        var arrival = 0
        columns[0].append(Path(), score: 0)
        func prefixGroups(_ paths: [Path]) -> [[Path]] {
            let groups = Dictionary(grouping: paths, by: \.sourceEnd)
            return groups.keys.sorted().map { groups[$0]! }
        }
        for start in 0..<count {
            if includesPartials, start > 0 {
                for group in prefixGroups(prefixColumns[start]) {
                    prefixes += prefixCandidates(group, consumed: input.rawBoundaries[group[0].sourceEnd],
                                                 source: source, learning: learning, now: now, context: context)
                }
                prefixColumns[start].removeAll()
            }
            let base = columns[start].finish()
            let personalized = tokenPreferences ? personalColumns[start].finish() : []
            var seen = Set<Int>()
            let paths = (base + personalized).filter { seen.insert($0.arrival).inserted }
            // A column can reach a word through several histories. Its outgoing static
            // bigram row depends only on the previous word, so compute that row once.
            var bigramRows: [String: [Double]] = [:]
            for path in paths {
                let previous = path.words.last ?? "\u{1}"
                let bonuses: [Double]
                if let cached = bigramRows[previous] { bonuses = cached }
                else {
                    bonuses = graph[start].map { edge in
                        2 * max(0, lexicon.bigram?.score([previous, edge.text]) ?? 0)
                    }
                    bigramRows[previous] = bonuses
                }
                for (index, edge) in graph[start].enumerated() {
                    guard edge.sourceStart == path.sourceEnd else { continue }
                    guard path.text.utf8.count + edge.text.utf8.count <= PinyinDecoder.maximumOutputBytes else { continue }
                    var next = path
                    arrival += 1
                    next.arrival = arrival
                    next.sourceEnd = edge.sourceEnd
                    next.text += edge.text
                    next.words.append(edge.text)
                    next.score += edge.score
                    if !path.words.isEmpty {
                        next.score -= CandidateScoring.languageCost(previous: 1, next: 1) * log(2.0)
                    }
                    next.score += edge.personal || path.personal ? 0 : bonuses[index]
                    next.personal = path.personal || edge.personal
                    next.tokenSum += edge.tokenBonus * Double(edge.letters)
                    next.letters += edge.letters
                    if evidence, !next.personal, path.words.count < 8 {
                        next.boundaries.append(ConfirmationBoundary(sourceCount: input.rawBoundaries[edge.sourceEnd],
                                                                    outputByteCount: next.text.utf8.count))
                    }
                    columns[edge.end].append(next, score: next.score)
                    if tokenPreferences || (edge.end == count && ranking.isActive) {
                        let score = edge.end == count ? ranking.score(candidate(next)) / Self.bitsPerNat
                            : next.score + next.tokenBonus / Self.bitsPerNat
                        personalColumns[edge.end].append(next, score: score)
                    }
                    // Prefix presentation has its own consumed-spelling objective. Keep a
                    // bounded pool before the continuation heap can discard such a path.
                    if includesPartials, edge.end < count, next.words.count > 1, !personalOnly || next.personal {
                        prefixColumns[edge.end].append(next)
                        if prefixColumns[edge.end].count > Self.beam * Self.spanLimit * 2 {
                            prefixColumns[edge.end] = prefixGroups(prefixColumns[edge.end]).flatMap { group in
                                prefixPaths(group, consumed: input.rawBoundaries[group[0].sourceEnd], source: source,
                                            learning: learning, now: now, context: context)
                            }
                        }
                    }
                }
            }
        }
        func finalized(_ paths: [Path], personalized: Bool) -> [Path] {
            var seen = Set<String>()
            var result = Array(paths.filter { (!personalOnly || $0.personal) && seen.insert($0.text).inserted }.prefix(Self.finalPaths))
            // Context evidence must not depend on how many other paths survived the beam.
            for index in result.indices { result[index].score = rescored(result[index]) }
            return result.sorted {
                let a = personalized ? ranking.score(candidate($0)) : $0.score
                let b = personalized ? ranking.score(candidate($1)) : $1.score
                return a > b
            }
        }
        let base = finalized(columns[count].finish(terminal: true), personalized: false)
        let personalized = ranking.isActive
            ? finalized(personalColumns[count].finish(terminal: true), personalized: true) : base
        var seen = Set<String>()
        // Evidence may inspect the retained alternatives, but must not change visible
        // candidates or ranking. Reject boundaries disputed by a plausible hidden path.
        let competitors = personalized + base
        return (Array(personalized.prefix(1)) + Array(base.prefix(1)))
            .filter { seen.insert($0.text).inserted }
            .map { path in
                guard evidence else { return path }
                var result = path
                let threshold = ranking.score(candidate(path)) - 3
                let plausible = competitors.filter { ranking.score(candidate($0)) >= threshold }
                result.boundaries = path.boundaries.filter { boundary in
                    let bytes = path.text.utf8.prefix(boundary.outputByteCount)
                    return plausible.allSatisfy {
                        !$0.personal && $0.boundaries.contains(boundary) && $0.text.utf8.starts(with: bytes)
                    }
                }
                return result
            }
    }

    private func rescored(_ path: Path) -> Double {
        guard !path.personal else { return path.score }
        var bonus = 0.0
        for position in path.words.indices {
            let before = position >= 2 ? path.words[position - 2] : "\u{1}"
            let previous = position >= 1 ? path.words[position - 1] : "\u{1}"
            bonus += lexicon.trigram?.score([before, previous, path.words[position]]) ?? 0
        }
        return path.score + bonus
    }

    private func prefixCandidates(_ paths: [Path], consumed: Int, source: String,
                                  learning: LearningProfile, now: Date, context: CandidateContext?) -> [InputCandidate] {
        prefixPaths(paths, consumed: consumed, source: source, learning: learning, now: now, context: context).map { path in
            let score = rescored(path) * Self.bitsPerNat
            return InputCandidate(text: path.text, language: .simplifiedChinese, score: Int(score),
                isUserPhrase: path.personal, consumedInputCount: consumed, rankingScore: score,
                tokenLearningBonus: path.tokenBonus, lexicalTokenCount: path.words.count)
        }
    }

    private func prefixPaths(_ paths: [Path], consumed: Int, source: String,
                             learning: LearningProfile, now: Date, context: CandidateContext?) -> [Path] {
        let ranking = learning.ranking(for: String(source.prefix(consumed)), now: now, context: context)
        let candidates: [(path: Path, candidate: InputCandidate, score: Double)] = paths.map { path in
            let score = rescored(path) * Self.bitsPerNat
            let candidate = InputCandidate(text: path.text, language: .simplifiedChinese, score: Int(score),
                isUserPhrase: path.personal, consumedInputCount: consumed, rankingScore: score,
                tokenLearningBonus: path.tokenBonus, lexicalTokenCount: path.words.count)
            return (path: path, candidate: candidate, score: ranking.score(candidate))
        }.sorted {
            $0.score == $1.score ? $0.candidate.id < $1.candidate.id : $0.score > $1.score
        }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.candidate.id).inserted }.prefix(2).map { $0.path }
    }

    private func wordScore(_ row: DictionaryLexeme, typed: [String]) -> Double {
        let cost = CandidateScoring.initialLanguageCost
            + CandidateScoring.wordCost(weight: row.weight, isChineseCharacter: row.reading.count == 1)
            + CandidateScoring.chineseSpellingCost(reading: row.reading, typed: typed)
        let context = 2 * max(0, lexicon.bigram?.score(["\u{1}", row.text]) ?? 0)
            + (lexicon.trigram?.score(["\u{1}", "\u{1}", row.text]) ?? 0)
        return -cost + context * Self.bitsPerNat
    }

    private static func completes(_ reading: [String], typed: [String]) -> Bool {
        guard reading.count >= typed.count, !typed.isEmpty else { return false }
        return zip(reading, typed).allSatisfy { $0.hasPrefix($1) } && reading != typed
    }
}
