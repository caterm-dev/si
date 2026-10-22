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
    /// For a fixed consumed syllable count, this is one insertion cost per token.
    /// Characters and words share the same log-frequency coefficient.
    private static let wordInsertionCost = 20.0
    /// A small anti-fragmentation cost: a tenfold frequency advantage (ln(10)) beats it.
    /// The former ln(1e6) cost erased even very large character-frequency advantages.
    private static let characterInsertionCost = 2.0
    /// MSIME's INSERTED_WEIGHT is an initial lexical prior, not an observed corpus count.
    private static let personalInitialWeight: Int64 = 10_000
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
        var score = 0.0
        var personal = false
        var tokenSum = 0.0
        var letters = 0
        var boundaries: [ConfirmationBoundary] = []
        var tokenBonus: Double { personal || letters == 0 ? 0 : min(32, tokenSum / Double(letters)) }
    }

    private struct Choice {
        var candidate: InputCandidate
        /// Exact lexical match, constructed sentence, then unfinished/abbreviated lookup.
        var group: Int
        var order: Int
        var cut = 0
        var lexicalScore: Double?
        var isWholeLookup = false
        var lookupOrder: Int?
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
        var alternativeOrder: [String: Int] = [:]
        for (index, row) in alternativeRows.enumerated() {
            let key = row.key + "\u{0}" + row.text
            if alternativeOrder[key] == nil { alternativeOrder[key] = index }
        }
        var primaryLookupCount = 0
        let ranking = learning.ranking(for: source, now: now, context: context)
        var choices: [Choice] = []
        var prefixes: [InputCandidate] = []
        for (cutIndex, reading) in cuts.enumerated() {
            let cut = reading.syllables
            let offsets = reading.offsets
            let normalized = cut.map(ChineseSyllables.canonical)
            // Alternative cuts contribute full-key dictionary rows. Re-running sentence
            // search on each alternative would change MSIME's primary sentence objective.
            var direct = cutIndex == 0 ? lexicon.matches(normalized, limit: preview ? 32 : nil)
                : alternativeRows.filter { $0.reading == normalized }
            if cutIndex == 0 {
                var seenWords = Set(direct.map(\.text))
                for split in ChineseLookupReadings.splitInitials(reading, input: input) {
                    direct += lexicon.matches(split.syllables, limit: preview ? 32 : nil)
                        .filter { seenWords.insert($0.text).inserted }
                }
                primaryLookupCount = direct.count
            }
            let exactCount = direct.filter { $0.reading == normalized }.count
            let directKeys = Set(direct.map { $0.key + "\u{0}" + $0.text })
            var lexical = direct
            // Longer completions remain available, but do not fill a page of exact homophones.
            if cutIndex == 0, exactCount < 5 { lexical += lexicon.completions(normalized) }
            var lexicalChoices: [(row: ChineseLexeme, candidate: InputCandidate, exact: Bool, order: Int)] = []
            for (index, row) in lexical.enumerated() {
                let exact = row.reading == normalized
                let completion = Self.completes(row.reading, typed: normalized)
                let candidate = InputCandidate(text: row.text, language: .simplifiedChinese,
                    score: Int(Self.wordScore(row.weight, syllables: row.reading.count)),
                    rankingScore: Self.wordScore(row.weight, syllables: row.reading.count),
                    hasCompletion: completion, lexicalTokenCount: exact || completion ? 1 : nil)
                lexicalChoices.append((row, candidate, exact, index))
            }
            lexicalChoices.sort {
                let a = log2(Double(max(1, $0.row.weight))) + (ranking.score($0.candidate) - $0.candidate.rankingScore)
                let b = log2(Double(max(1, $1.row.weight))) + (ranking.score($1.candidate) - $1.candidate.rankingScore)
                return a == b ? $0.order < $1.order : a > b
            }
            // Pin the strongest exact reading, then let completions compete by dictionary
            // frequency for later seats. Whole sentences follow the leading exact run.
            if !(normalized.count == 1 && normalized[0].count == 1),
               let firstExact = lexicalChoices.firstIndex(where: { $0.exact }), firstExact > 0 {
                lexicalChoices.insert(lexicalChoices.remove(at: firstExact), at: 0)
            }
            let leadingExact = lexicalChoices.prefix(while: { $0.exact }).count
            for (index, value) in lexicalChoices.enumerated() {
                let key = value.row.key + "\u{0}" + value.row.text
                let lookupOrder = cutIndex == 0 ? value.order
                    : primaryLookupCount + (alternativeOrder[key] ?? value.order)
                choices.append(Choice(candidate: value.candidate, group: index < leadingExact ? 0 : 2,
                    order: choices.count, cut: cutIndex, lexicalScore: log2(Double(max(1, value.row.weight))),
                    isWholeLookup: directKeys.contains(key), lookupOrder: lookupOrder))
            }
            guard cutIndex == 0 else { continue }
            if exactCount >= 5 {
                for row in lexicon.completions(normalized) {
                    let candidate = InputCandidate(text: row.text, language: .simplifiedChinese,
                        score: Int(Self.wordScore(row.weight, syllables: row.reading.count)),
                        rankingScore: Self.wordScore(row.weight, syllables: row.reading.count),
                        hasCompletion: true, lexicalTokenCount: 1)
                    choices.append(Choice(candidate: candidate, group: 3, order: choices.count, cut: cutIndex,
                                          lexicalScore: log2(Double(max(1, row.weight)))))
                }
            }

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
                                prefixes.append(InputCandidate(text: row.text, language: .simplifiedChinese,
                                    score: Int(Self.wordScore(row.weight, syllables: span.count)),
                                    consumedInputCount: input.rawBoundaries[offsets[end]],
                                    rankingScore: Self.wordScore(row.weight, syllables: span.count),
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
                    choices.append(Choice(candidate: candidate, group: 1, order: choices.count, cut: cutIndex))
                }
            }
            if choices.count + prefixes.count < 8 {
                for fallback in ChineseLookupReadings.sparseFallbacks(reading) {
                    let consumed = input.rawBoundaries[fallback.offsets.last!]
                    for row in lexicon.matches(fallback.syllables, limit: preview ? 32 : nil) {
                        let score = Self.wordScore(row.weight, syllables: row.reading.count)
                        let candidate = InputCandidate(text: row.text, language: .simplifiedChinese,
                            score: Int(score), consumedInputCount: consumed < source.count ? consumed : nil,
                            rankingScore: score, lexicalTokenCount: row.reading == fallback.syllables ? 1 : nil)
                        if candidate.isPartial {
                            if includesPartials { prefixes.append(candidate) }
                        } else {
                            choices.append(Choice(candidate: candidate, group: 4, order: choices.count,
                                                  lexicalScore: log2(Double(max(1, row.weight)))))
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
                    choices.append(Choice(candidate: candidate, group: 1, order: choices.count))
                }
            }
            if includesPartials, input.letters.count > 1 {
                for end in 1...min(input.letters.count - 1, dictionary.maximumCodeLength) {
                    let code = String(input.letters[..<end])
                    for phrase in dictionary.directPhrases(for: code) where phrase.language == .simplifiedChinese
                        && input.respects(phrase.boundaries, from: 0, to: end) {
                        let score = Self.wordScore(Self.personalInitialWeight, syllables: max(1, phrase.boundaries.count + 1))
                            + (phrase.isPinned ? 1 : 0)
                        prefixes.append(InputCandidate(text: phrase.text, language: .simplifiedChinese,
                            score: Int(score), isUserPhrase: true, consumedInputCount: input.rawBoundaries[end],
                            rankingScore: score, lexicalTokenCount: 1))
                    }
                }
            }
        }
        for candidate in dictionary.candidates(for: source, languages: [.simplifiedChinese]).sorted(by: { $0.id < $1.id }) {
            choices.append(Choice(candidate: candidate, group: candidate.isPreferred ? -1 : 0, order: choices.count))
        }
        var best: [String: Choice] = [:]
        for var choice in choices {
            if let previous = best[choice.candidate.id] {
                let better: Bool
                if choice.candidate.isPreferred != previous.candidate.isPreferred {
                    better = choice.candidate.isPreferred
                } else {
                    let current = ranking.score(choice.candidate), old = ranking.score(previous.candidate)
                    better = current > old || (current == old && choice.candidate.isUserPhrase && !previous.candidate.isUserPhrase)
                }
                var retained = better ? choice.candidate : previous.candidate
                retained.retainLexicalEvidence(from: better ? previous.candidate : choice.candidate)
                choice.candidate = retained
                choice.group = min(choice.group, previous.group)
                choice.cut = min(choice.cut, previous.cut)
                choice.order = min(choice.order, previous.order)
                if let old = previous.lexicalScore {
                    let current = choice.lexicalScore ?? -.infinity
                    if old > current || (old == current && (previous.lookupOrder ?? previous.order) < (choice.lookupOrder ?? choice.order)) {
                        choice.lexicalScore = old
                        choice.lookupOrder = previous.lookupOrder
                    }
                }
                choice.isWholeLookup = previous.isWholeLookup || choice.isWholeLookup
            }
            best[choice.candidate.id] = choice
        }
        var sorted = best.values.sorted {
            if $0.candidate.isPreferred != $1.candidate.isPreferred { return $0.candidate.isPreferred }
            if ($0.cut == 0) != ($1.cut == 0) { return $0.cut == 0 }
            if $0.group != $1.group { return $0.group < $1.group }
            let left = ($0.lexicalScore ?? $0.candidate.rankingScore) + (ranking.score($0.candidate) - $0.candidate.rankingScore)
            let right = ($1.lexicalScore ?? $1.candidate.rankingScore) + (ranking.score($1.candidate) - $1.candidate.rankingScore)
            if left != right { return left > right }
            if $0.order != $1.order { return $0.order < $1.order }
            return $0.candidate.id < $1.candidate.id
        }
        // Alternative full-key readings compete with the primary dictionary rows by
        // frequency. A viable alternative outside the first six gets a second seat.
        if sorted.contains(where: { $0.cut > 0 && $0.isWholeLookup }) {
            let primaryFrequency = sorted.filter { $0.cut == 0 && $0.isWholeLookup }.compactMap(\.lexicalScore).max()
            let alternative = sorted.filter { $0.cut > 0 && $0.isWholeLookup }.max {
                ($0.lexicalScore ?? -.infinity) < ($1.lexicalScore ?? -.infinity)
            }
            var whole = sorted.filter(\.isWholeLookup).sorted {
                let a = ($0.lexicalScore ?? 0) + (ranking.score($0.candidate) - $0.candidate.rankingScore)
                let b = ($1.lexicalScore ?? 0) + (ranking.score($1.candidate) - $1.candidate.rankingScore)
                return a == b ? ($0.lookupOrder ?? $0.order) < ($1.lookupOrder ?? $1.order) : a > b
            }
            if let alternative,
               (alternative.lexicalScore ?? -.infinity) >= (primaryFrequency ?? -.infinity) - log2(100.0),
               let index = whole.firstIndex(where: { $0.candidate.id == alternative.candidate.id }), index >= 6 {
                whole.insert(whole.remove(at: index), at: 1)
            }
            sorted = whole + sorted.filter { !$0.isWholeLookup }
            if let preferred = sorted.firstIndex(where: { $0.candidate.isPreferred }), preferred > 0 {
                sorted.insert(sorted.remove(at: preferred), at: 0)
            }
        }
        let ordered = sorted.map(\.candidate)
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
        var lookup: [String: [ChineseLexeme]] = [:]
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
                    let rows: [ChineseLexeme]
                    if let cached = lookup[key] { rows = cached }
                    else {
                        rows = span.count <= Self.maximumWordSyllables && span.allSatisfy(ChineseSyllables.complete.contains)
                            ? lexicon.exactMatches(span, limit: Self.spanLimit) : []
                        lookup[key] = rows
                    }
                    let spelling = input.rawText(from: offsets[start], to: offsets[end])
                    for row in rows {
                        graph[start].append(Edge(end: end, sourceStart: offsets[start], sourceEnd: offsets[end], text: row.text,
                            score: Self.wordLogScore(row.weight, syllables: end - start), personal: false,
                            tokenBonus: learning.tokenBonus(input: spelling, text: row.text, language: .simplifiedChinese, now: now),
                            letters: offsets[end] - offsets[start]))
                    }
                    let code = String(input.letters[offsets[start]..<offsets[end]])
                    for phrase in dictionary.phrases(for: code) where phrase.language == .simplifiedChinese
                        && input.respects(phrase.boundaries, from: offsets[start], to: offsets[end]) {
                        graph[start].append(Edge(end: end, sourceStart: offsets[start], sourceEnd: offsets[end], text: phrase.text,
                            score: Self.wordLogScore(Self.personalInitialWeight, syllables: end - start)
                                + (phrase.isPinned ? log(2.0) : 0), personal: true,
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
                    next.score += bonuses[index]
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
            // The upstream does not add a trigram term when only one sentence survived.
            if result.count > 1 {
                for index in result.indices { result[index].score = rescored(result[index]) }
            }
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

    private static func wordScore(_ weight: Int64, syllables: Int) -> Double {
        wordLogScore(weight, syllables: syllables) * bitsPerNat
    }

    private static func wordLogScore(_ weight: Int64, syllables: Int) -> Double {
        let value = log(Double(max(1, weight)))
        // Sum(log(weight) - insertionCost) plus the path's constant syllable offset.
        // The former extra ln(1e6) character penalty rewarded low-frequency fragments
        // whenever they absorbed an otherwise natural standalone character.
        return value + wordInsertionCost * Double(max(0, syllables - 1))
            - (syllables <= 1 ? characterInsertionCost : 0)
    }

    private static func completes(_ reading: [String], typed: [String]) -> Bool {
        guard reading.count >= typed.count, !typed.isEmpty else { return false }
        return zip(reading, typed).allSatisfy { $0.hasPrefix($1) } && reading != typed
    }
}
