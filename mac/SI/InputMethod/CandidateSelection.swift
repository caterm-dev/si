#if SWIFT_PACKAGE
import SICore
#endif

// One client owns the selected cell, numbered row and displayed page.
struct CandidateSelection {
    enum Navigation: Equatable {
        case column(Int)
        case row(Int)
        case page(Int)
    }

    enum Action: Equatable {
        case expand
        case navigate(Navigation)
        case choose(Int)
    }

    static let pageSize = 6
    static let compactPageSize = pageSize
    static let expandedRowCount = 4
    private(set) var isExpanded = false
    var visiblePageSize: Int { Self.pageSize }
    var pageCapacity: Int { Self.pageSize * (isExpanded ? Self.expandedRowCount : 1) }
    private(set) var candidates: [InputCandidate] = []
    private(set) var selectedIndex = 0

    var selected: InputCandidate? { candidates.indices.contains(selectedIndex) ? candidates[selectedIndex] : nil }
    var page: Int { selectedIndex / pageCapacity }
    var pageCount: Int { (candidates.count + pageCapacity - 1) / pageCapacity }
    var row: Int { (selectedIndex % pageCapacity) / Self.pageSize }
    // Digits always address the selected row's six columns.
    var visibleRange: Range<Int> {
        let start = selectedIndex / Self.pageSize * Self.pageSize
        return start..<min(start + Self.pageSize, candidates.count)
    }

    var displayedRange: Range<Int> {
        let start = page * pageCapacity
        return start..<min(start + pageCapacity, candidates.count)
    }

    static func action(keyCode: UInt16, characters: String?, pageSize: Int = Self.pageSize,
                       isExpanded: Bool = false) -> Action? {
        switch keyCode {
        case 123: return .navigate(.column(-1))
        case 124: return .navigate(.column(1))
        case 125: return isExpanded ? .navigate(.row(1)) : .expand
        case 126: return isExpanded ? .navigate(.row(-1)) : .navigate(.column(-1))
        case 116: return .navigate(.page(-1))
        case 121: return .navigate(.page(1))
        default:
            guard let characters, characters.count == 1, "123456789".contains(characters),
                  let number = Int(characters), number <= pageSize else { return nil }
            return .choose(number)
        }
    }

    mutating func update(_ candidates: [InputCandidate]) {
        self.candidates = CandidateShortlist.candidates(from: candidates)
        selectedIndex = 0
        if candidates.isEmpty { isExpanded = false }
    }

    mutating func setExpanded(_ expanded: Bool) { isExpanded = expanded }

    mutating func move(by offset: Int) {
        guard !candidates.isEmpty else { return }
        selectedIndex = max(0, min(candidates.count - 1, selectedIndex + offset))
    }

    mutating func navigate(_ navigation: Navigation) {
        guard !candidates.isEmpty else { return }
        switch navigation {
        case .column(let offset):
            if isExpanded {
                selectedIndex = max(visibleRange.lowerBound, min(visibleRange.upperBound - 1, selectedIndex + offset))
            } else {
                move(by: offset)
            }
        case .row(let offset):
            guard isExpanded else { return }
            let column = selectedIndex % Self.pageSize
            let lastRow = (displayedRange.count - 1) / Self.pageSize
            let nextRow = max(0, min(lastRow, row + offset))
            selectedIndex = min(displayedRange.upperBound - 1,
                                displayedRange.lowerBound + nextRow * Self.pageSize + column)
        case .page(let offset):
            movePage(by: offset)
        }
    }

    mutating func movePage(by offset: Int) {
        guard !candidates.isEmpty else { return }
        let nextPage = max(0, min(pageCount - 1, page + offset))
        selectedIndex = min(candidates.count - 1, nextPage * pageCapacity + selectedIndex % pageCapacity)
    }

    func candidate(number: Int) -> InputCandidate? {
        guard (1...Self.pageSize).contains(number) else { return nil }
        let index = visibleRange.lowerBound + number - 1
        return visibleRange.contains(index) ? candidates[index] : nil
    }
}
