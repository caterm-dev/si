#if SWIFT_PACKAGE
import SICore
#endif

// One client owns this state. The window and all selection keys use the same page/index.
struct CandidateSelection {
    enum Action: Equatable {
        case move(Int)
        case choose(Int)
    }

    static let pageSize = 9
    static let maximumCandidates = 27
    private(set) var isExpanded = false
    var visiblePageSize: Int { isExpanded ? Self.pageSize : 5 }
    private(set) var candidates: [InputCandidate] = []
    private(set) var selectedIndex = 0

    var selected: InputCandidate? { candidates.indices.contains(selectedIndex) ? candidates[selectedIndex] : nil }
    var page: Int { selectedIndex / visiblePageSize }
    var pageCount: Int { (candidates.count + visiblePageSize - 1) / visiblePageSize }
    var visibleRange: Range<Int> {
        let start = page * visiblePageSize
        return start..<min(start + visiblePageSize, candidates.count)
    }

    static func action(keyCode: UInt16, characters: String?, pageSize: Int = Self.pageSize,
                       isExpanded: Bool = false) -> Action? {
        switch keyCode {
        case 123: return isExpanded ? .move(-pageSize) : nil
        case 124: return isExpanded ? .move(pageSize) : nil
        case 125: return .move(1)
        case 126: return .move(-1)
        case 116: return .move(-pageSize)
        case 121: return .move(pageSize)
        default:
            guard let characters, characters.count == 1, "123456789".contains(characters),
                  let number = Int(characters) else { return nil }
            return .choose(number)
        }
    }

    mutating func update(_ candidates: [InputCandidate], prefixScore: ((InputCandidate) -> Double)? = nil) {
        let whole = candidates.indices.filter { !candidates[$0].isPartial && !candidates[$0].isLiteral && !candidates[$0].isHistory }.prefix(2)
        let history = candidates.indices.filter { candidates[$0].isHistory }
        let partialIndices = candidates.indices.filter { candidates[$0].isPartial }
        let scored: [(index: Int, score: Double)] = partialIndices.map {
            (index: $0, score: prefixScore?(candidates[$0]) ?? candidates[$0].rankingScore)
        }
        let rankedPrefixes = scored.sorted {
            $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score
        }.map { $0.index }
        let lexical = rankedPrefixes.filter { candidates[$0].isLexicalPrefix }
        if let first = whole.first, (candidates[first].lexicalTokenCount ?? 0) > 1, !lexical.isEmpty {
            // A sentence fallback should help choose the next word, not fill later pages with more sentences.
            let characters = lexical.filter { candidates[$0].language == .simplifiedChinese && candidates[$0].text.count == 1 }
            let characterIndices = Set(characters)
            let words = lexical.filter { !characterIndices.contains($0) }
            let featured = Array(whole) + history + words + characters
            let featuredIndices = Set(featured)
            let required = Self.protectedIDs(candidates)
            let fallbacks = candidates.indices.filter { !featuredIndices.contains($0) && required.contains(candidates[$0].id) }
            let ordered = (featured + fallbacks).map { candidates[$0] }
            self.candidates = Self.shortlist(ordered, engineCandidates: candidates)
            selectedIndex = 0
            return
        }
        // Single words and unknown provider results retain the ordinary ranked shortlist.
        let prefixes = Array(rankedPrefixes.prefix(7))
        let featured = Array(whole) + history + prefixes
        let featuredIndices = Set(featured)
        let ordered = prefixes.isEmpty ? candidates
            : (featured + candidates.indices.filter { !featuredIndices.contains($0) }).map { candidates[$0] }
        self.candidates = Self.shortlist(ordered, engineCandidates: candidates)
        selectedIndex = 0
        if candidates.isEmpty { isExpanded = false }
    }

    private static func protectedIDs(_ engineCandidates: [InputCandidate]) -> Set<String> {
        // Reserve a complete choice per language identity before considering prefix-only fallbacks.
        var languages: Set<InputLanguage> = []
        var includesMixed = false
        var retainedIDs: Set<String> = []
        if let history = engineCandidates.first(where: \.isHistory) { retainedIDs.insert(history.id) }
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

    private static func shortlist(_ ordered: [InputCandidate], engineCandidates: [InputCandidate]) -> [InputCandidate] {
        guard ordered.count > maximumCandidates else { return ordered }
        var retainedIDs = protectedIDs(engineCandidates)
        for candidate in ordered {
            guard retainedIDs.count < maximumCandidates else { break }
            retainedIDs.insert(candidate.id)
        }
        return ordered.filter { retainedIDs.contains($0.id) }
    }

    mutating func setExpanded(_ expanded: Bool) { isExpanded = expanded }

    mutating func move(by offset: Int) {
        guard !candidates.isEmpty else { return }
        selectedIndex = max(0, min(candidates.count - 1, selectedIndex + offset))
    }

    mutating func movePage(by offset: Int) { move(by: offset * visiblePageSize) }

    func candidate(number: Int) -> InputCandidate? {
        guard (1...visiblePageSize).contains(number) else { return nil }
        let index = page * visiblePageSize + number - 1
        return visibleRange.contains(index) ? candidates[index] : nil
    }
}
