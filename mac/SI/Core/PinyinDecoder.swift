import Foundation
import Darwin

/// Shared bounded word lattice for Pinyin, English, and explicit personal phrases.
public struct PinyinDecoder: Sendable {
    public static let standard = PinyinDecoder(entries: ChineseLexiconData.entries)
    public static let maximumOutputBytes = 4_096
    private struct Reading: Sendable {
        let entries: [Int]
        let previewEntries: [Int]
        let boundaries: Set<Int>
        let penalty: Int
    }
    private struct Edge {
        let end: Int
        let text: String
        let languages: Int
        let cost: Double
        let score: Int
        var personal = false
        var verbatim = false
        var abbreviated = false
        var completion = false
        var learningBonus = 0.0
    }
    private struct Path {
        let text: String
        // Only all-lexical English paths carry word spacing. Mixed/personal output keeps its exact bytes.
        let englishText: String?
        let cost: Double
        let languages: Int
        let lastLanguage: Int
        let segments: Int
        let directScore: Int
        let personal: Bool
        let verbatim: Bool
        let completion: Bool
        let learnedSum: Double
        let consumedLetters: Int
        let supportsByteComparison: Bool
        let englishWordEnd: Int
        let splitsEnglishWord: Bool

        var learningBonus: Double {
            personal || verbatim || splitsEnglishWord || consumedLetters == 0 ? 0 : min(32, learnedSum / Double(consumedLetters))
        }
        var searchCost: Double { cost - learningBonus * 10 }
        var comparisonText: String { englishText ?? text }
    }
    private struct PathIdentity: Hashable {
        let state: Int
        let text: String
        let supportsByteComparison: Bool
        let englishWordEnd: Int
        let splitsEnglishWord: Bool

        init(state: Int, path: Path, continuing: Bool = false) {
            self.state = state
            text = path.comparisonText
            supportsByteComparison = path.supportsByteComparison
            englishWordEnd = continuing ? path.englishWordEnd : 0
            splitsEnglishWord = continuing && path.splitsEnglishWord
        }

        static func == (left: Self, right: Self) -> Bool {
            left.state == right.state && left.englishWordEnd == right.englishWordEnd
                && left.splitsEnglishWord == right.splitsEnglishWord && left.text == right.text
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(state)
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
    }
    private let entries: [PinyinLexiconEntry]
    private let readings: [Reading]
    private let exact: [String: [Int]]
    private let fullCodes: [String]
    private let fullReadings: [Int]
    private let maximumCodeLength: Int
    private static let beamWidth = 12

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
        for group in groups {
            let entry = entries[group[0]]
            // Source order is not frequency order. Prepare the bounded hint pool once,
            // so a common syllable cannot lose its strongest words before path scoring.
            let previewEntries = Array(group.sorted {
                if entries[$0].score != entries[$1].score { return entries[$0].score > entries[$1].score }
                return $0 < $1
            }.prefix(16))
            maximum = max(maximum, entry.code.count)
            let index = readings.count
            readings.append(Reading(entries: group, previewEntries: previewEntries, boundaries: entry.boundaries, penalty: 0))
            exact[entry.code, default: []].append(index)
            full.append((entry.code, index))
            guard entry.syllables.count > 1 else { continue }
            let masks = entry.syllables.count <= 6 ? Array(1..<(1 << entry.syllables.count)) : [-1]
            var seen: Set<String> = [entry.code]
            for mask in masks {
                var code = ""
                var boundaries = Set<Int>()
                var shortened = 0
                for (position, syllable) in entry.syllables.enumerated() {
                    let initial = mask == -1 || mask & (1 << position) != 0
                    let token = initial ? String(syllable.prefix(1)) : syllable
                    if token != syllable { shortened += 1 }
                    code += token
                    if position < entry.syllables.count - 1 { boundaries.insert(code.count) }
                }
                guard seen.insert(code).inserted else { continue }
                exact[code, default: []].append(readings.count)
                readings.append(Reading(entries: group, previewEntries: previewEntries, boundaries: boundaries,
                                        penalty: 18 + min(4, shortened * 2)))
            }
        }
        full.sort { $0.code == $1.code ? $0.reading < $1.reading : $0.code < $1.code }
        self.entries = entries
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
                                      preview: Bool = false) -> [InputCandidate] {
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
        paths[0] = [Path(text: "", englishText: "", cost: 0, languages: 0, lastLanguage: 0, segments: 0, directScore: 0,
                         personal: false, verbatim: false, completion: false, learnedSum: 0, consumedLetters: 0,
                         supportsByteComparison: true, englishWordEnd: 0, splitsEnglishWord: false)]
        for start in 0..<count where !paths[start].isEmpty {
            var options = outgoing[start]
            let needsUnknown = options.contains(where: \.completion)
                || !options.contains(where: { !$0.abbreviated && !$0.completion })
            if mayPreserveUnknown && needsUnknown {
                let ends = anchors.filter { $0 > start } + [count]
                for end in ends {
                    options.append(Edge(end: end, text: reading.rawText(from: start, to: end), languages: 2,
                                        cost: 25 + Double(end - start) * 2, score: 0, verbatim: true))
                }
            }
            for edge in options {
                // ASCII and unified CJK ideographs are NFC and cannot compose across segment boundaries.
                // Other text keeps Swift's full canonical comparison, including combining marks/emoji.
                let supportsBytes = edge.text.unicodeScalars.allSatisfy {
                    $0.isASCII || (0x3400...0x4dbf).contains($0.value) || (0x4e00...0x9fff).contains($0.value)
                }
                for path in paths[start] {
                    guard path.text.utf8.count + edge.text.utf8.count <= Self.maximumOutputBytes else { continue }
                    let transition = path.lastLanguage == 0 || path.lastLanguage == edge.languages ? 0.0 : 4.0
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
                    paths[edge.end].append(Path(text: text, englishText: englishText, cost: path.cost + edge.cost + transition,
                                               languages: path.languages | edge.languages, lastLanguage: edge.languages,
                                               segments: path.segments + 1,
                                               directScore: edge.score, personal: path.personal || edge.personal,
                                               verbatim: path.verbatim || edge.verbatim, completion: path.completion || edge.completion,
                                               learnedSum: path.learnedSum + edge.learningBonus * Double(edge.end - start),
                                               consumedLetters: edge.end,
                                               supportsByteComparison: path.supportsByteComparison && supportsBytes,
                                               englishWordEnd: englishWordEnd, splitsEnglishWord: splitsEnglishWord))
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
            results.append(InputCandidate(text: edge.text, language: .simplifiedChinese, score: edge.score,
                                          isUserPhrase: edge.personal, hasCompletion: edge.completion))
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
            let spelling = result.consumedInputCount.map { String(input.prefix($0)) } ?? input
            let score = learning.rankingScore(for: result, input: spelling, now: now, context: context)
            if let previous = best[result.id], previous.score > score
                || (previous.score == score && !result.isUserPhrase) { continue }
            best[result.id] = (result, score)
        }
        return best.values.sorted {
            if $0.candidate.isPartial != $1.candidate.isPartial { return !$0.candidate.isPartial }
            if $0.candidate.isPartial, $0.candidate.consumedInputCount != $1.candidate.consumedInputCount {
                return ($0.candidate.consumedInputCount ?? 0) > ($1.candidate.consumedInputCount ?? 0)
            }
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.candidate.id < $1.candidate.id
        }.map(\.candidate)
    }

    private func edges(for input: PinyinInput, languages: Set<InputLanguage>, dictionary: UserDictionary,
                       learning: LearningProfile, now: Date, preview: Bool) -> [[Edge]] {
        let count = input.letters.count
        let chinese = languages.contains(.simplifiedChinese)
        let english = languages.contains(.english)
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
                    let matches = preview ? Array(fullReadingRange(from: code, to: code + "a").prefix(8)) : exact[code] ?? []
                    for index in matches {
                        let match = readings[index]
                        guard input.respects(match.boundaries, from: start, to: end) else { continue }
                        for index in preview ? match.previewEntries : match.entries {
                            let entry = entries[index]
                            let score = entry.score - match.penalty
                            result[start].append(Edge(end: end, text: entry.text, languages: 1,
                                                      cost: 8 + Double(max(0, 100 - score)) / 4, score: score,
                                                      abbreviated: match.penalty > 0))
                        }
                    }
                }
                for phrase in dictionary.phrases(for: code) where languages.contains(phrase.language)
                    && input.respects(phrase.boundaries, from: start, to: end) {
                    result[start].append(Edge(end: end, text: phrase.text, languages: phrase.language == .english ? 2 : 1,
                                              cost: phrase.isPinned ? 1 : 4, score: phrase.isPinned ? 180 : 115, personal: true))
                }
                // Walk the same English prefix once, stopping permanently at a failed
                // transition or an explicit syllable boundary inside this span.
                if end > start + 1 && input.separators.contains(end - 1) { englishNode = nil }
                if let node = englishNode {
                    englishNode = EnglishLexicon.advance(node, byte: input.letters[end - 1].asciiValue!)
                    if let next = englishNode, let entry = EnglishLexicon.exactMatch(at: next) {
                        let style = EnglishLexicon.CaseStyle(input: String(input.originalLetters[start..<end]))
                        result[start].append(Edge(end: end, text: entry.text(for: style),
                                                  languages: 2, cost: 8, score: 110))
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
                        result[start].append(Edge(end: count, text: entry.text, languages: 1,
                                                  cost: 24 + Double(max(0, 100 - entry.score)) / 4,
                                                  score: entry.score - 16, completion: true))
                    }
                }
            }
            if count - start >= 2, count - start <= longest, let node = englishNode {
                let style = EnglishLexicon.CaseStyle(input: String(input.originalLetters[start..<count]))
                let matches = EnglishLexicon.completions(at: node)
                for entry in preview ? matches.prefix(8) : matches {
                    result[start].append(Edge(end: count, text: entry.text(for: style),
                                              languages: 2, cost: entry.completionCost,
                                              score: entry.completionScore, completion: true))
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
                    let a = ($0.cost - $0.learningBonus * 10) / Double($0.end - start)
                    let b = ($1.cost - $1.learningBonus * 10) / Double($1.end - start)
                    if a != b { return a < b }
                    if $0.end != $1.end { return $0.end > $1.end }
                    return $0.text < $1.text
                }.filter {
                    let key = $0.languages | ($0.completion ? 4 : 0)
                    let spanKey = key | ($0.end << 3)
                    guard counts[spanKey, default: 0] < 2,
                          spans[key, default: []].contains($0.end) || spans[key, default: []].count < 2 else { return false }
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
                              hasCompletion: path.completion, tokenLearningBonus: path.segments > 1 ? path.learningBonus : 0)
    }

    private func baseScore(_ path: Path, consumed: Int?) -> Double {
        let fullScore = path.segments == 1 ? Double(path.directScore) : max(0, 94 - path.cost / 10 - (path.verbatim ? 12 : 0))
        return consumed == nil ? fullScore : fullScore - 26
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
        return PresentationPath(path: path, baseScore: base, effectiveScore: effective)
    }

    private func presentationPrecedes(_ left: PresentationPath, _ right: PresentationPath, personalized: Bool) -> Bool {
        let a = personalized ? left.effectiveScore : left.baseScore
        let b = personalized ? right.effectiveScore : right.baseScore
        if a != b { return a > b }
        if left.path.personal != right.path.personal { return left.path.personal }
        if left.path.verbatim != right.path.verbatim { return !left.path.verbatim }
        return Self.textPrecedes(left.path, right.path)
    }

    private func selectTerminal(_ paths: [PresentationPath], personalized: Bool) -> [PresentationPath] {
        var groups: [Int: [PresentationPath]] = [:]
        for value in paths {
            let key = state(value.path)
            var group = groups[key, default: []]
            if group.count == Self.beamWidth,
               !presentationPrecedes(value, group[group.count - 1], personalized: personalized) { continue }
            if let duplicate = group.firstIndex(where: { Self.textEquals($0.path, value.path) }) {
                guard presentationPrecedes(value, group[duplicate], personalized: personalized) else { continue }
                group.remove(at: duplicate)
            }
            let position = group.firstIndex { presentationPrecedes(value, $0, personalized: personalized) } ?? group.count
            group.insert(value, at: position)
            if group.count > Self.beamWidth { group.removeLast() }
            groups[key] = group
        }
        return groups.values.flatMap { $0 }.sorted { presentationPrecedes($0, $1, personalized: personalized) }
    }

    private func selectPrefixes(_ paths: [PresentationPath]) -> [PresentationPath] {
        var groups: [Int: [PresentationPath]] = [:]
        for value in paths {
            let key = value.path.languages
            var group = groups[key, default: []]
            if group.count == 2, !presentationPrecedes(value, group[1], personalized: true) { continue }
            if let duplicate = group.firstIndex(where: { Self.textEquals($0.path, value.path) }) {
                guard presentationPrecedes(value, group[duplicate], personalized: true) else { continue }
                group[duplicate] = value
                group.sort { presentationPrecedes($0, $1, personalized: true) }
            } else {
                let position = group.firstIndex { presentationPrecedes(value, $0, personalized: true) } ?? group.count
                group.insert(value, at: position)
                if group.count > 2 { group.removeLast() }
            }
            groups[key] = group
        }
        return [1, 2, 3].flatMap { groups[$0, default: []] }
    }

    private func state(_ path: Path) -> Int {
        path.languages | (path.verbatim ? 4 : 0) | (path.lastLanguage << 3) | (path.completion ? 32 : 0)
    }

    private func preferred(_ left: Path, _ right: Path) -> Bool {
        if left.searchCost != right.searchCost { return left.searchCost < right.searchCost }
        if left.verbatim != right.verbatim { return !left.verbatim }
        if left.personal != right.personal { return !left.personal }
        return Self.continuationPrecedes(left, right)
    }

    private func select(_ paths: [Path], personalized: Bool) -> [Path] {
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
            let key = state(path)
            var group = groups[key, default: []]
            if group.count == Self.beamWidth, !precedes(path, group[group.count - 1].path) { continue }
            if let duplicate = group.firstIndex(where: {
                $0.path.englishWordEnd == path.englishWordEnd && $0.path.splitsEnglishWord == path.splitsEnglishWord
                    && Self.textEquals($0.path, path)
            }) {
                guard precedes(path, group[duplicate].path) else { continue }
                group.remove(at: duplicate)
            }
            let position = group.firstIndex { precedes(path, $0.path) } ?? group.count
            group.insert((path, order), at: position)
            if group.count > Self.beamWidth { group.removeLast() }
            groups[key] = group
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
