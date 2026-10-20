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

    static func action(keyCode: UInt16, characters: String?, pageSize: Int = Self.pageSize) -> Action? {
        switch keyCode {
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
        // Feature two complete choices, then useful word/character prefixes, without dropping any result.
        let whole = candidates.indices.filter { !candidates[$0].isPartial && !candidates[$0].isLiteral }.prefix(2)
        let partialIndices = candidates.indices.filter { candidates[$0].isPartial }
        let scored: [(index: Int, score: Double)] = partialIndices.map {
            (index: $0, score: prefixScore?(candidates[$0]) ?? candidates[$0].rankingScore)
        }
        let prefixes = scored.sorted {
            $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score
        }.prefix(7).map { $0.index }
        let featured = Array(whole) + prefixes
        let featuredIndices = Set(featured)
        self.candidates = prefixes.isEmpty ? candidates
            : (featured + candidates.indices.filter { !featuredIndices.contains($0) }).map { candidates[$0] }
        selectedIndex = 0
        if candidates.isEmpty { isExpanded = false }
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
