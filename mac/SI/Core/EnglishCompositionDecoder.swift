import Foundation
import Darwin

/// Existing English lexical composition, isolated while the Chinese decoder is migrated.
/// Production calls this lane with English only; Chinese lookup belongs to ChineseDecoder.
struct EnglishCompositionDecoder: Sendable {
    static let standard = EnglishCompositionDecoder(entries: [])
    public static let maximumOutputBytes = 4_096
    private struct Reading: Sendable {
        let entries: [Int]
        let previewEntries: [Int]
        let boundaries: Set<Int>
        let channelCost: Double
        let abbreviated: Bool
    }
    private struct Edge {
        let end: Int
        let text: String
        let languages: Int
        let cost: Double
        let token: Int
        var channelCost = 0.0
        var preferred = false
        var personal = false
        var verbatim = false
        var abbreviated = false
        var completion = false
        var learningBonus = 0.0
    }
    private struct Path {
        var confirmationTrace: ConfirmationTrace?
        let text: String
        // Only all-lexical English paths carry word spacing. Mixed/personal output keeps its exact bytes.
        let englishText: String?
        let cost: Double
        let languages: Int
        let lastLanguage: Int
        let segments: Int
        let lastToken: Int
        let contextID: Int
        let preferred: Bool
        let personal: Bool
        let verbatim: Bool
        let abbreviated: Bool
        let completion: Bool
        let learnedSum: Double
        let consumedLetters: Int
        let supportsByteComparison: Bool
        let englishWordEnd: Int
        let splitsEnglishWord: Bool

        var learningBonus: Double {
            personal || verbatim || splitsEnglishWord || consumedLetters == 0 ? 0 : min(32, learnedSum / Double(consumedLetters))
        }
        var searchCost: Double { cost - learningBonus / LexicalLanguageModel.pointsPerBit }
        var comparisonText: String { englishText ?? text }
    }
    // Shared immutable tails avoid copying an array on every lattice expansion. Capture is opt-in,
    // full-search only, and stops after eight leading words or the first non-exact Chinese edge.
    private final class ConfirmationTrace {
        let boundary: ConfirmationBoundary
        let previous: ConfirmationTrace?
        let count: Int

        init(boundary: ConfirmationBoundary, previous: ConfirmationTrace?) {
            self.boundary = boundary
            self.previous = previous
            count = (previous?.count ?? 0) + 1
        }

        var boundaries: [ConfirmationBoundary] {
            var result: [ConfirmationBoundary] = []
            var trace: ConfirmationTrace? = self
            while let current = trace {
                result.append(current.boundary)
                trace = current.previous
            }
            return result.reversed()
        }
    }
    private struct PathIdentity: Hashable {
        let state: Int
        let text: String
        let supportsByteComparison: Bool
        let englishWordEnd: Int
        let splitsEnglishWord: Bool
        let contextID: Int
        let learningBonus: Double

        init(state: Int, path: Path, continuing: Bool = false) {
            self.state = state
            text = path.comparisonText
            supportsByteComparison = path.supportsByteComparison
            contextID = continuing ? path.contextID : 0
            learningBonus = continuing ? path.learningBonus : 0
            englishWordEnd = continuing ? path.englishWordEnd : 0
            splitsEnglishWord = continuing && path.splitsEnglishWord
        }

        static func == (left: Self, right: Self) -> Bool {
            left.state == right.state && left.contextID == right.contextID && left.learningBonus == right.learningBonus
                && left.englishWordEnd == right.englishWordEnd
                && left.splitsEnglishWord == right.splitsEnglishWord && left.text == right.text
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(state)
            hasher.combine(contextID)
            hasher.combine(learningBonus)
            hasher.combine(englishWordEnd)
            hasher.combine(splitsEnglishWord)
            // Both branches hash the same canonical UTF-8 bytes, including cross-branch equivalents.
            var canonical = supportsByteComparison ? text : text.precomposedStringWithCanonicalMapping
            canonical.withUTF8 { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
        }
    }
    private struct PresentationPath {
        let path: Path
        let baseScore: Double
        let effectiveScore: Double
        let isPreferred: Bool
    }
    private let entries: [PinyinLexiconEntry]
    private let model: LexicalLanguageModel
    private let exactChannelCosts: [Double]
    private let readings: [Reading]
    private let exact: [String: [Int]]
    private let fullCodes: [String]
    private let fullReadings: [Int]
    private let maximumCodeLength: Int
    private static let beamWidth = 12
    private static let protectedFullSpellings = 2

    public init(entries source: [PinyinLexiconEntry]) {
        let entries = source.filter { entry in
            !entry.text.isEmpty && entry.text.utf8.count <= Self.maximumOutputBytes && (0...200).contains(entry.score)
                && !entry.syllables.isEmpty && entry.code.count <= 64
                && entry.syllables.allSatisfy { !$0.isEmpty && $0.utf8.allSatisfy { $0 >= 97 && $0 <= 122 } }
        }
        // Words sharing one reading also share its full/initial variants and boundary metadata.
        var groups: [[Int]] = []
        var groupForReading: [String: Int] = [:]
        for index in entries.indices {
            let key = entries[index].syllables.joined(separator: "'")
            if let group = groupForReading[key] { groups[group].append(index) }
            else {
                groupForReading[key] = groups.count
                groups.append([index])
            }
        }
        var readings: [Reading] = []
        var exact: [String: [Int]] = [:]
        var full: [(code: String, reading: Int)] = []
        var maximum = 0
        let model = LexicalLanguageModel(entries: entries)
        let exactChannelCosts = entries.map { entry in
            PinyinSpellingChannel.cost(syllables: entry.syllables, typedLength: entry.code.count)
        }
        let lexicalScores = entries.indices.map {
            -(model.costs[model.chineseIDs[$0]] + model.readingCosts[$0] + exactChannelCosts[$0]) * LexicalLanguageModel.pointsPerBit
        }
        for group in groups {
            let entry = entries[group[0]]
            // Source order is not frequency order. Prepare the bounded hint pool once,
            // so a common syllable cannot lose its strongest words before path scoring.
            let previewEntries = Array(group.sorted {
                if lexicalScores[$0] != lexicalScores[$1] { return lexicalScores[$0] > lexicalScores[$1] }
                return $0 < $1
            }.prefix(16))
            maximum = max(maximum, entry.code.count)
            let index = readings.count
            readings.append(Reading(entries: group, previewEntries: previewEntries, boundaries: entry.boundaries, channelCost: 0, abbreviated: false))
            exact[entry.code, default: []].append(index)
            full.append((entry.code, index))
            guard entry.syllables.count > 1 else { continue }
            let masks = entry.syllables.count <= 6 ? Array(1..<(1 << entry.syllables.count)) : [-1]
            var seen: Set<String> = [entry.code]
            for mask in masks {
                var code = ""
                var boundaries = Set<Int>()
                var channelCost = 0.0
                for (position, syllable) in entry.syllables.enumerated() {
                    let initial = mask == -1 || mask & (1 << position) != 0
                    let token = initial ? String(syllable.prefix(1)) : syllable
                    code += token
                    channelCost += PinyinSpellingChannel.cost(length: syllable.count, typedLength: token.count)
                    if position < entry.syllables.count - 1 { boundaries.insert(code.count) }
                }
                guard seen.insert(code).inserted else { continue }
                exact[code, default: []].append(readings.count)
                readings.append(Reading(entries: group, previewEntries: previewEntries, boundaries: boundaries,
                                        channelCost: channelCost,
                                        abbreviated: true))
            }
        }
        full.sort { $0.code == $1.code ? $0.reading < $1.reading : $0.code < $1.code }
        self.entries = entries
        self.model = model
        self.exactChannelCosts = exactChannelCosts
        self.readings = readings
        self.exact = exact
        fullCodes = full.map(\.code)
        fullReadings = full.map(\.reading)
        maximumCodeLength = maximum
    }

    private func fullReadingRange(from lowerKey: String, to upperKey: String) -> ArraySlice<Int> {
        func lowerBound(_ key: String) -> Int {
            var lower = 0
            var upper = fullCodes.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if fullCodes[middle] < key { lower = middle + 1 } else { upper = middle }
            }
            return lower
        }
        return fullReadings[lowerBound(lowerKey)..<lowerBound(upperKey)]
    }

    private func completions(for prefix: String) -> ArraySlice<Int> {
        // Codes contain only a...z; exclude exact codes and include every longer full spelling.
        fullReadingRange(from: prefix + "a", to: prefix + "{")
    }

    public func candidates(for input: String) -> [InputCandidate] {
        compositionCandidates(for: input, languages: [.simplifiedChinese], includesPartials: false, allowsVerbatim: false)
    }

    public func mixedCandidates(for input: String) -> [InputCandidate] {
        compositionCandidates(for: input, languages: [.english, .simplifiedChinese],
                              includesPartials: false, allowsVerbatim: false).filter(\.isMixed)
    }

    public func compositionCandidates(for input: String, languages: Set<InputLanguage>,
                                      dictionary: UserDictionary = UserDictionary(),
                                      learning: LearningProfile = LearningProfile(), now: Date = .now,
                                      context: CandidateContext? = nil,
                                      includesPartials: Bool = true, allowsVerbatim: Bool = true,
                                      preview: Bool = false, includesConfirmationEvidence: Bool = false) -> [InputCandidate] {
        guard let reading = PinyinInput(input), !languages.isEmpty else { return [] }
        let count = reading.letters.count
        let terminalRanking = learning.ranking(for: input, now: now, context: context)
        let outgoing = edges(for: reading, languages: languages, dictionary: dictionary, learning: learning, now: now,
                             preview: preview)
        // Only exact lexical English spans protect a boundary; completions and personal/raw nodes do not.
        let hasTokenBonuses = outgoing.contains { $0.contains { $0.learningBonus > 0 } }
        let englishEnds = hasTokenBonuses ? outgoing.map { edges in
            edges.filter { $0.languages == 2 && !$0.personal && !$0.completion && !$0.verbatim }
                .map(\.end).max() ?? 0
        } : Array(repeating: 0, count: count)
        var exactReachable = Array(repeating: false, count: count + 1)
        exactReachable[0] = true
        for start in 0..<count where exactReachable[start] {
            for edge in outgoing[start] where !edge.completion && !edge.abbreviated { exactReachable[edge.end] = true }
        }
        let mayPreserveUnknown = allowsVerbatim && !exactReachable[count]
            && languages.contains(.english) && languages.contains(.simplifiedChinese)
        let anchors = (0..<count).filter { outgoing[$0].contains { $0.languages == 1 } }
        var paths = Array(repeating: [Path](), count: count + 1)
        var prefixes = Array(repeating: [PresentationPath](), count: count + 1)
        var prefixRankings: [Int: LearningProfile.Ranking] = [:]
        paths[0] = [Path(text: "", englishText: "", cost: 0, languages: 0, lastLanguage: 0, segments: 0, lastToken: 0, contextID: 0,
                         preferred: false, personal: false, verbatim: false, abbreviated: false, completion: false, learnedSum: 0, consumedLetters: 0,
                         supportsByteComparison: true, englishWordEnd: 0, splitsEnglishWord: false)]
        for start in 0..<count where !paths[start].isEmpty {
            var options = outgoing[start]
            let needsUnknown = options.contains(where: \.completion)
                || !options.contains(where: { !$0.abbreviated && !$0.completion })
            if mayPreserveUnknown && needsUnknown {
                let ends = anchors.filter { $0 > start } + [count]
                for end in ends {
                    options.append(Edge(end: end, text: reading.rawText(from: start, to: end), languages: 2,
                                        cost: model.costs[0] + Double(end - start) * log2(26), token: 0, verbatim: true))
                }
            }
            for edge in options {
                // ASCII and unified CJK ideographs are NFC and cannot compose across segment boundaries.
                // Other text keeps Swift's full canonical comparison, including combining marks/emoji.
                let supportsBytes = edge.text.unicodeScalars.allSatisfy {
                    $0.isASCII || (0x3400...0x4dbf).contains($0.value) || (0x4e00...0x9fff).contains($0.value)
                }
                let contextID = model.contextIdentity(for: edge.token)
                for path in paths[start] {
                    guard path.text.utf8.count + edge.text.utf8.count <= Self.maximumOutputBytes else { continue }
                    let increment = edge.token == 0 ? edge.cost
                        : edge.channelCost + model.cost(token: edge.token, after: path.lastToken)
                    let excludesLearning = path.personal || path.verbatim || edge.personal || edge.verbatim
                    let splitsEnglishWord = !excludesLearning && (path.splitsEnglishWord
                        || (path.lastLanguage == 2 && start < path.englishWordEnd)
                        || (edge.abbreviated && edge.end < englishEnds[start]))
                    // Reusing word preferences must not invent a token boundary inside an exact English word.
                    // Whole-input preferences still apply to a deliberately selected alternative segmentation.
                    let englishWordEnd = edge.languages == 2 && !excludesLearning && !splitsEnglishWord
                        ? max(path.englishWordEnd, englishEnds[start]) : 0
                    let text = path.text + edge.text
                    let englishText = edge.languages == 2 && !edge.personal && !edge.verbatim
                        ? path.englishText.map { $0.isEmpty ? edge.text : $0 + " " + edge.text } : nil
                    guard englishText.map({ $0.utf8.count <= Self.maximumOutputBytes }) ?? true else { continue }
                    var next = Path(text: text, englishText: englishText, cost: path.cost + increment,
                                               languages: path.languages | edge.languages, lastLanguage: edge.languages,
                                               segments: path.segments + 1,
                                               lastToken: edge.token, contextID: contextID, preferred: path.segments == 0 && edge.preferred, personal: path.personal || edge.personal,
                                               verbatim: path.verbatim || edge.verbatim, abbreviated: path.abbreviated || edge.abbreviated,
                                               completion: path.completion || edge.completion,
                                               learnedSum: path.learnedSum + edge.learningBonus * Double(edge.end - start),
                                               consumedLetters: edge.end,
                                               supportsByteComparison: path.supportsByteComparison && supportsBytes,
                                               englishWordEnd: englishWordEnd, splitsEnglishWord: splitsEnglishWord)
                    if includesConfirmationEvidence && !preview {
                        next.confirmationTrace = path.confirmationTrace
                        if path.segments < 8, (path.segments == 0 || path.confirmationTrace?.count == path.segments),
                           edge.languages == 1, !edge.personal, !edge.verbatim, !edge.abbreviated, !edge.completion {
                            next.confirmationTrace = ConfirmationTrace(
                                boundary: ConfirmationBoundary(sourceCount: reading.rawBoundaries[edge.end],
                                                               outputByteCount: text.utf8.count),
                                previous: path.confirmationTrace)
                        }
                    }
                    paths[edge.end].append(next)
                }
                // Terminal scores are final, so retaining their bounded best sets is associative.
                // Compact large completion batches before they allocate an unbounded temporary pool.
                if edge.end == count, paths[count].count >= Self.beamWidth * 64 {
                    paths[count] = terminalPaths(paths[count], ranking: terminalRanking)
                }
            }
            // Keep incoming paths bounded before each subsequent position is expanded.
            let affected = Set(options.map(\.end))
            for end in affected {
                if end == count {
                    paths[end] = terminalPaths(paths[end], ranking: terminalRanking)
                } else {
                    if includesPartials {
                        let ranking = prefixRankings[end]
                            ?? learning.ranking(for: reading.rawText(from: 0, to: end), now: now, context: context)
                        prefixRankings[end] = ranking
                        let incoming = paths[end].filter { !$0.verbatim }.map {
                            presentation($0, consumed: reading.rawBoundaries[end], ranking: ranking)
                        }
                        prefixes[end] = selectPrefixes(prefixes[end] + incoming)
                    }
                    paths[end] = prune(paths[end])
                }
            }
        }

        var results = preview ? [] : dictionary.candidates(for: input, languages: languages)
        // Direct lexical matches/completions are not restricted by the constructed-path beam.
        for edge in outgoing[0] where edge.end == count && edge.languages == 1 {
            results.append(InputCandidate(text: edge.text, language: .simplifiedChinese, score: Int(-edge.cost * LexicalLanguageModel.pointsPerBit),
                                          isUserPhrase: edge.personal, rankingScore: -edge.cost * LexicalLanguageModel.pointsPerBit, hasCompletion: edge.completion,
                                          isPreferred: edge.preferred, lexicalTokenCount: edge.abbreviated ? nil : 1))
        }
        for path in paths[count] where eligible(path) {
            results.append(candidate(path))
        }
        if includesPartials, count > 1 {
            for end in 1..<count {
                for value in prefixes[end] {
                    results.append(candidate(value.path, consumed: reading.rawBoundaries[end]))
                }
            }
        }
        var best: [String: (candidate: InputCandidate, score: Double)] = [:]
        best.reserveCapacity(results.count)
        for result in results {
            var result = result
            let spelling = result.consumedInputCount.map { String(input.prefix($0)) } ?? input
            let score = learning.rankingScore(for: result, input: spelling, now: now, context: context)
            if let previous = best[result.id],
               (previous.candidate.isPreferred && !result.isPreferred)
                || (previous.candidate.isPreferred == result.isPreferred
                    && (previous.score > score || (previous.score == score && !result.isUserPhrase))) {
                best[result.id]?.candidate.retainLexicalEvidence(from: result)
                continue
            }
            if let previous = best[result.id] { result.retainLexicalEvidence(from: previous.candidate) }
            best[result.id] = (result, score)
        }
        return best.values.sorted {
            if $0.candidate.isPartial != $1.candidate.isPartial { return !$0.candidate.isPartial }
            if $0.candidate.isPartial, $0.candidate.consumedInputCount != $1.candidate.consumedInputCount {
                return ($0.candidate.consumedInputCount ?? 0) > ($1.candidate.consumedInputCount ?? 0)
            }
            if $0.candidate.isPreferred != $1.candidate.isPreferred { return $0.candidate.isPreferred }
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.candidate.id < $1.candidate.id
        }.map(\.candidate)
    }

    private func edges(for input: PinyinInput, languages: Set<InputLanguage>, dictionary: UserDictionary,
                       learning: LearningProfile, now: Date, preview: Bool) -> [[Edge]] {
        let count = input.letters.count
        let chinese = languages.contains(.simplifiedChinese)
        let english = languages.contains(.english)
        let personalBaseCost = log2(Double(max(1, dictionary.phraseCount)))
        let longest = max(chinese ? maximumCodeLength : 0, english ? EnglishLexicon.maximumLength : 0,
                          dictionary.maximumCodeLength)
        var result = Array(repeating: [Edge](), count: count)
        guard longest > 0 else { return result }
        for start in 0..<count {
            var englishNode: Int? = english ? 0 : nil
            for end in (start + 1)...min(count, start + longest) {
                let code = String(input.letters[start..<end])
                if chinese {
                    // Early hints bound lexical fanout in the same lattice; final search stays exhaustive at lookup.
                    let matches: [Int]
                    if preview {
                        let full = Array(fullReadingRange(from: code, to: code + "a").prefix(8))
                        let initial = (exact[code] ?? []).lazy.filter { readings[$0].abbreviated }.prefix(8 - full.count)
                        matches = full + initial
                    } else { matches = exact[code] ?? [] }
                    for index in matches {
                        let match = readings[index]
                        guard input.respects(match.boundaries, from: start, to: end) else { continue }
                        for index in preview ? match.previewEntries : match.entries {
                            let entry = entries[index]
                            let channel = match.abbreviated ? match.channelCost : exactChannelCosts[index]
                            result[start].append(Edge(end: end, text: entry.text, languages: 1,
                                                      cost: model.costs[model.chineseIDs[index]] + model.readingCosts[index] + channel,
                                                      token: model.chineseIDs[index], channelCost: model.readingCosts[index] + channel,
                                                      abbreviated: match.abbreviated))
                        }
                    }
                }
                for phrase in dictionary.phrases(for: code) where languages.contains(phrase.language)
                    && input.respects(phrase.boundaries, from: start, to: end) {
                    result[start].append(Edge(end: end, text: phrase.text, languages: phrase.language == .english ? 2 : 1,
                                              cost: personalBaseCost + (phrase.isPinned ? 0 : 1), token: 0, preferred: phrase.isPinned, personal: true))
                }
                // Walk the same English prefix once, stopping permanently at a failed
                // transition or an explicit syllable boundary inside this span.
                if end > start + 1 && input.separators.contains(end - 1) { englishNode = nil }
                if let node = englishNode {
                    englishNode = EnglishLexicon.advance(node, byte: input.letters[end - 1].asciiValue!)
                    if let next = englishNode, let entry = EnglishLexicon.exactMatch(at: next) {
                        let style = EnglishLexicon.CaseStyle(input: String(input.originalLetters[start..<end]))
                        result[start].append(Edge(end: end, text: entry.text(for: style),
                                                  languages: 2, cost: entry.cost(typedLength: end - start), token: entry.id,
                                                  channelCost: entry.channelCost(typedLength: end - start)))
                    }
                }
            }
            if chinese {
                let suffix = String(input.letters[start..<count])
                let matches = completions(for: suffix)
                for index in preview ? matches.prefix(8) : matches {
                    let match = readings[index]
                    guard input.respectsCompletion(match.boundaries, from: start, to: count) else { continue }
                    for index in preview ? match.previewEntries : match.entries {
                        let entry = entries[index]
                        let channel = model.readingCosts[index]
                            + PinyinSpellingChannel.cost(syllables: entry.syllables, typedLength: count - start)
                        result[start].append(Edge(end: count, text: entry.text, languages: 1,
                                                  cost: model.costs[model.chineseIDs[index]] + channel,
                                                  token: model.chineseIDs[index], channelCost: channel, completion: true))
                    }
                }
            }
            if count - start >= 2, count - start <= longest, let node = englishNode {
                let style = EnglishLexicon.CaseStyle(input: String(input.originalLetters[start..<count]))
                let matches = preview ? EnglishLexicon.previewCompletions(at: node) : Array(EnglishLexicon.completions(at: node))
                for entry in matches {
                    result[start].append(Edge(end: count, text: entry.text(for: style),
                                              languages: 2, cost: entry.cost(typedLength: count - start),
                                              token: entry.id, channelCost: entry.channelCost(typedLength: count - start), completion: true))
                }
            }
            if learning.hasTokenPreferences {
                let positions = Dictionary(grouping: result[start].indices.filter { !result[start][$0].personal }, by: { result[start][$0].end })
                for (end, indices) in positions {
                    let spelling = input.rawText(from: start, to: end)
                    let chineseKey = LearningProfile.normalizedInput(spelling, language: .simplifiedChinese)
                    let englishKey = spelling.lowercased()
                    guard learning.hasTokenPreferences(for: chineseKey) || learning.hasTokenPreferences(for: englishKey) else { continue }
                    for index in indices {
                        let edge = result[start][index]
                        result[start][index].learningBonus = learning.tokenBonus(
                            normalizedInput: edge.languages == 1 ? chineseKey : englishKey, text: edge.text,
                            language: edge.languages == 1 ? .simplifiedChinese : .english, now: now)
                    }
                }
            }
        }
        if preview {
            for start in result.indices {
                var counts: [Int: Int] = [:]
                var spans: [Int: Set<Int>] = [:]
                result[start] = result[start].sorted {
                    // Prefer words that cover more spelling when reducing the provisional edge set.
                    let a = ($0.cost - $0.learningBonus / LexicalLanguageModel.pointsPerBit) / Double($0.end - start)
                    let b = ($1.cost - $1.learningBonus / LexicalLanguageModel.pointsPerBit) / Double($1.end - start)
                    if a != b { return a < b }
                    if $0.end != $1.end { return $0.end > $1.end }
                    return $0.text < $1.text
                }.filter {
                    let key = $0.languages | ($0.completion ? 4 : 0) | ($0.abbreviated ? 8 : 0)
                    let spanKey = key | ($0.end << 4)
                    guard counts[spanKey, default: 0] < ($0.abbreviated ? 8 : 16),
                          spans[key, default: []].contains($0.end) || spans[key, default: []].count < 4 else { return false }
                    spans[key, default: []].insert($0.end)
                    counts[spanKey, default: 0] += 1
                    return true
                }
            }
        }
        return result
    }

    private func eligible(_ path: Path) -> Bool {
        path.languages != 2 || (!path.verbatim && (path.personal || (path.englishText != nil && path.segments > 1)))
    }

    private func candidate(_ path: Path, consumed: Int? = nil) -> InputCandidate {
        let score = baseScore(path, consumed: consumed)
        return InputCandidate(text: path.comparisonText, language: path.languages == 2 ? .english : .simplifiedChinese,
                              score: Int(score), isMixed: path.languages == 3, isUserPhrase: path.personal,
                              hasLiteralSegments: path.verbatim, consumedInputCount: consumed, rankingScore: score,
                              hasCompletion: path.completion, tokenLearningBonus: path.segments > 1 ? path.learningBonus : 0,
                              isPreferred: consumed == nil && path.segments == 1 && path.preferred,
                              lexicalTokenCount: path.segments == 1 && path.abbreviated ? nil : path.segments,
                              confirmationBoundaries: consumed == nil ? path.confirmationTrace?.boundaries ?? [] : [])
    }

    private func baseScore(_ path: Path, consumed: Int?) -> Double {
        // Prefix actions are ordered separately; their score uses only consumed spelling.
        -(path.cost + LexicalLanguageModel.terminalCost) * LexicalLanguageModel.pointsPerBit
    }

    private func prune(_ paths: [Path]) -> [Path] {
        let base = select(paths, personalized: false)
        guard paths.contains(where: { $0.learningBonus > 0 }) else { return base }
        // Keep a baseline beam as well, so learned tokens do not crowd out ordinary alternatives.
        let personalized = select(paths, personalized: true)
        var seen = Set<PathIdentity>()
        return (base + personalized).sorted(by: preferred).filter {
            seen.insert(PathIdentity(state: state($0), path: $0, continuing: true)).inserted
        }
    }

    /// Terminal paths will never be extended, so use displayed scores rather than continuation costs.
    private func terminalPaths(_ paths: [Path], ranking: LearningProfile.Ranking) -> [Path] {
        let values = paths.filter(eligible).map { presentation($0, consumed: nil, ranking: ranking) }
        let base = selectTerminal(values, personalized: false)
        guard values.contains(where: { $0.effectiveScore != $0.baseScore }) else { return base.map(\.path) }
        let personalized = selectTerminal(values, personalized: true)
        var seen = Set<PathIdentity>()
        return (base + personalized).sorted { presentationPrecedes($0, $1, personalized: true) }.filter {
            seen.insert(PathIdentity(state: state($0.path), path: $0.path)).inserted
        }.map(\.path)
    }

    private func presentation(_ path: Path, consumed: Int?, ranking: LearningProfile.Ranking) -> PresentationPath {
        let base = baseScore(path, consumed: consumed)
        let effective: Double
        if ranking.hasWholePreferences && !path.personal && !path.verbatim {
            effective = ranking.score(candidate(path, consumed: consumed))
        } else {
            effective = base + (ranking.isActive && path.segments > 1 ? path.learningBonus : 0)
        }
        return PresentationPath(path: path, baseScore: base, effectiveScore: effective,
                                isPreferred: consumed == nil && path.segments == 1 && path.preferred)
    }

    private func presentationPrecedes(_ left: PresentationPath, _ right: PresentationPath, personalized: Bool) -> Bool {
        if left.isPreferred != right.isPreferred { return left.isPreferred }
        let a = personalized ? left.effectiveScore : left.baseScore
        let b = personalized ? right.effectiveScore : right.baseScore
        if a != b { return a > b }
        if left.path.personal != right.path.personal { return left.path.personal }
        if left.path.verbatim != right.path.verbatim { return !left.path.verbatim }
        return Self.textPrecedes(left.path, right.path)
    }

    private func selectTerminal(_ paths: [PresentationPath], personalized: Bool,
                                limit: Int = Self.beamWidth, reservingFull: Bool = true) -> [PresentationPath] {
        var groups: [Int: [PresentationPath]] = [:]
        for value in paths {
            let key = state(value.path) & ~64
            var group = groups[key, default: []]
            if group.count == limit,
               !presentationPrecedes(value, group[group.count - 1], personalized: personalized) { continue }
            if let duplicate = group.firstIndex(where: { Self.textEquals($0.path, value.path) }) {
                guard presentationPrecedes(value, group[duplicate], personalized: personalized) else { continue }
                group.remove(at: duplicate)
            }
            let position = group.firstIndex { presentationPrecedes(value, $0, personalized: personalized) } ?? group.count
            group.insert(value, at: position)
            if group.count > limit { group.removeLast() }
            groups[key] = group
        }
        if reservingFull && paths.contains(where: { $0.path.abbreviated }) {
            let full = selectTerminal(paths.filter { !$0.path.abbreviated }, personalized: personalized,
                                      limit: Self.protectedFullSpellings, reservingFull: false)
            for (key, protected) in Dictionary(grouping: full, by: { state($0.path) & ~64 }) {
                let general = groups[key, default: []]
                // Keep both top sets independently. Replacing general slots with
                // protected paths would make incremental compaction non-associative.
                let additional = protected.filter { value in
                    !general.contains { !$0.path.abbreviated && Self.textEquals($0.path, value.path) }
                }
                groups[key] = (general + additional).sorted { presentationPrecedes($0, $1, personalized: personalized) }
            }
        }
        return groups.values.flatMap { $0 }.sorted { presentationPrecedes($0, $1, personalized: personalized) }
    }

    private func selectPrefixes(_ paths: [PresentationPath]) -> [PresentationPath] {
        var groups: [Int: [PresentationPath]] = [:]
        for value in paths {
            // Keep a bounded set of first-word alternatives independently of composed prefixes.
            let lexical = value.path.segments == 1 && !value.path.abbreviated
            let key = value.path.languages | (lexical ? 4 : 0)
            let limit = lexical ? 24 : 2
            var group = groups[key, default: []]
            if group.count == limit, !presentationPrecedes(value, group[limit - 1], personalized: true) { continue }
            if let duplicate = group.firstIndex(where: { Self.textEquals($0.path, value.path) }) {
                guard presentationPrecedes(value, group[duplicate], personalized: true) else { continue }
                group[duplicate] = value
                group.sort { presentationPrecedes($0, $1, personalized: true) }
            } else {
                let position = group.firstIndex { presentationPrecedes(value, $0, personalized: true) } ?? group.count
                group.insert(value, at: position)
                if group.count > limit { group.removeLast() }
            }
            groups[key] = group
        }
        return [1, 2, 3, 5, 6, 7].flatMap { groups[$0, default: []] }
    }

    private func state(_ path: Path) -> Int {
        // Spelling provenance participates in path identity; selection shares its
        // budget across spellings with up to two additional full-spelling alternatives.
        path.languages | (path.verbatim ? 4 : 0) | (path.lastLanguage << 3)
            | (path.completion ? 32 : 0) | (path.abbreviated ? 64 : 0)
    }

    private func preferred(_ left: Path, _ right: Path) -> Bool {
        if left.searchCost != right.searchCost { return left.searchCost < right.searchCost }
        if left.verbatim != right.verbatim { return !left.verbatim }
        if left.personal != right.personal { return !left.personal }
        return Self.continuationPrecedes(left, right)
    }

    private func select(_ paths: [Path], personalized: Bool,
                        limit: Int = Self.beamWidth, reservingFull: Bool = true) -> [Path] {
        func precedes(_ left: Path, _ right: Path) -> Bool {
            let a = personalized ? left.searchCost : left.cost
            let b = personalized ? right.searchCost : right.cost
            if a != b { return a < b }
            if left.verbatim != right.verbatim { return !left.verbatim }
            if left.personal != right.personal { return !left.personal }
            return Self.continuationPrecedes(left, right)
        }
        // Retain the same best distinct paths without sorting the entire incoming pool.
        // The budget and identity include the same future boundary/learning information.
        var groups: [Int: [(path: Path, order: Int)]] = [:]
        for (order, path) in paths.enumerated() {
            let key = state(path) & ~64
            var group = groups[key, default: []]
            if group.count == limit, !precedes(path, group[group.count - 1].path) { continue }
            if let duplicate = group.firstIndex(where: {
                $0.path.contextID == path.contextID && $0.path.englishWordEnd == path.englishWordEnd && $0.path.splitsEnglishWord == path.splitsEnglishWord
                    && $0.path.abbreviated == path.abbreviated
                    && Self.textEquals($0.path, path)
            }) {
                guard precedes(path, group[duplicate].path) else { continue }
                group.remove(at: duplicate)
            }
            let position = group.firstIndex { precedes(path, $0.path) } ?? group.count
            group.insert((path, order), at: position)
            if group.count > limit { group.removeLast() }
            groups[key] = group
        }
        if reservingFull && paths.contains(where: \.abbreviated) {
            let full = select(paths.filter { !$0.abbreviated }, personalized: personalized,
                              limit: Self.protectedFullSpellings, reservingFull: false)
            for (key, protected) in Dictionary(grouping: full, by: { state($0) & ~64 }) {
                let reserved = protected.enumerated().map { index, path in
                    groups[key, default: []].first {
                        PathIdentity(state: state($0.path), path: $0.path, continuing: true)
                            == PathIdentity(state: state(path), path: path, continuing: true)
                    } ?? (path: path, order: paths.count + index)
                }
                groups[key, default: []].append(contentsOf: reserved.filter { $0.order >= paths.count })
            }
        }
        return groups.values.flatMap { $0 }.sorted {
            if precedes($0.path, $1.path) { return true }
            if precedes($1.path, $0.path) { return false }
            return $0.order < $1.order
        }.map(\.path)
    }

    private static func continuationPrecedes(_ left: Path, _ right: Path) -> Bool {
        if left.englishWordEnd == right.englishWordEnd && left.splitsEnglishWord == right.splitsEnglishWord {
            return textPrecedes(left, right)
        }
        if !textEquals(left, right) { return textPrecedes(left, right) }
        if left.splitsEnglishWord != right.splitsEnglishWord { return !left.splitsEnglishWord }
        return left.englishWordEnd < right.englishWordEnd
    }

    private static func textPrecedes(_ left: Path, _ right: Path) -> Bool {
        guard left.supportsByteComparison && right.supportsByteComparison else { return left.comparisonText < right.comparisonText }
        return compareBytes(left.comparisonText, right.comparisonText) < 0
    }

    private static func textEquals(_ left: Path, _ right: Path) -> Bool {
        guard left.supportsByteComparison && right.supportsByteComparison else { return left.comparisonText == right.comparisonText }
        return compareBytes(left.comparisonText, right.comparisonText) == 0
    }

    private static func compareBytes(_ left: String, _ right: String) -> Int {
        var lhs = left
        var rhs = right
        return lhs.withUTF8 { a in
            rhs.withUTF8 { b in
                let count = min(a.count, b.count)
                guard count > 0 else { return a.count - b.count }
                // Positive length guarantees nonnil bases; the read is bounded by both buffer lengths.
                let order = memcmp(a.baseAddress!, b.baseAddress!, count)
                return order == 0 ? a.count - b.count : Int(order)
            }
        }
    }
}
