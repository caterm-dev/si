#if SWIFT_PACKAGE
import SICore
#endif

// One client owns this state. The window and all selection keys use the same page/index.
struct CandidateSelection {
    enum Action: Equatable {
        case expand
        case move(Int)
        case choose(Int)
    }

    static let pageSize = 6
    static let compactPageSize = pageSize
    static let expandedRowCount = 4
    static let maximumCandidates = CandidateShortlist.maximumCandidates
    private(set) var isExpanded = false
    var visiblePageSize: Int { Self.pageSize }
    private(set) var candidates: [InputCandidate] = []
    private(set) var selectedIndex = 0

    var selected: InputCandidate? { candidates.indices.contains(selectedIndex) ? candidates[selectedIndex] : nil }
    var page: Int { selectedIndex / visiblePageSize }
    var pageCount: Int { (candidates.count + visiblePageSize - 1) / visiblePageSize }
    var visibleRange: Range<Int> {
        let start = page * visiblePageSize
        return start..<min(start + visiblePageSize, candidates.count)
    }

    var displayedRange: Range<Int> {
        guard isExpanded else { return visibleRange }
        let count = Self.pageSize * Self.expandedRowCount
        let start = selectedIndex / count * count
        return start..<min(start + count, candidates.count)
    }

    static func action(keyCode: UInt16, characters: String?, pageSize: Int = Self.pageSize,
                       isExpanded: Bool = false) -> Action? {
        switch keyCode {
        case 123: return isExpanded ? .move(-pageSize) : nil
        case 124: return isExpanded ? .move(pageSize) : nil
        case 125: return isExpanded ? .move(1) : .expand
        case 126: return .move(-1)
        case 116: return .move(-pageSize)
        case 121: return .move(pageSize)
        default:
            guard let characters, characters.count == 1, "123456789".contains(characters),
                  let number = Int(characters), number <= pageSize else { return nil }
            return .choose(number)
        }
    }

    mutating func update(_ candidates: [InputCandidate]) {
        // The shared shortlist applies sentence placement; all page/selection actions use it.
        self.candidates = CandidateShortlist.candidates(from: candidates)
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
