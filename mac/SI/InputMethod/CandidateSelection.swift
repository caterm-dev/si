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

    mutating func update(_ candidates: [InputCandidate]) {
        // Ranking belongs to the engine. Shortlisting never reorders retained choices.
        self.candidates = Self.shortlist(candidates)
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

    private static func shortlist(_ candidates: [InputCandidate]) -> [InputCandidate] {
        guard candidates.count > maximumCandidates else { return candidates }
        var retainedIDs = protectedIDs(candidates)
        for candidate in candidates {
            guard retainedIDs.count < maximumCandidates else { break }
            retainedIDs.insert(candidate.id)
        }
        return candidates.filter { retainedIDs.contains($0.id) }
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
