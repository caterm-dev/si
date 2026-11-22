#if SWIFT_PACKAGE
import SICore
#endif

// One client owns the selected cell, numbered row and scroll position.
struct CandidateSelection {
    /// The displayed global first choice stays neutral, including number/mouse acceptance.
    func confirmationReason(for candidate: InputCandidate?) -> CommitReason {
        guard let candidate else { return .literal }
        if candidate.requiresExplicitSelection { return .explicitSelection }
        return candidate.id == candidates.first?.id ? .defaultAcceptance : .explicitSelection
    }
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
    static let expandedRowCount = 5
    private(set) var isExpanded = false
    var visiblePageSize: Int { Self.pageSize }
    private(set) var candidates: [InputCandidate] = []
    private(set) var selectedIndex = 0
    private var firstVisibleRow = 0
    private var textSupport = CandidateTextSupport()

    var selected: InputCandidate? { candidates.indices.contains(selectedIndex) ? candidates[selectedIndex] : nil }
    var row: Int { selectedIndex / Self.pageSize }
    var rowCount: Int { (candidates.count + Self.pageSize - 1) / Self.pageSize }
    // Digits always address the selected row's six columns.
    var visibleRange: Range<Int> {
        let start = row * Self.pageSize
        return start..<min(start + Self.pageSize, candidates.count)
    }

    var displayedRange: Range<Int> {
        guard isExpanded else { return visibleRange }
        let start = firstVisibleRow * Self.pageSize
        return start..<min(start + Self.expandedRowCount * Self.pageSize, candidates.count)
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
        if candidates.isEmpty { textSupport = CandidateTextSupport() }
        self.candidates = shortlist(candidates)
        selectedIndex = 0
        firstVisibleRow = 0
        if self.candidates.isEmpty { isExpanded = false }
    }

    private mutating func shortlist(_ candidates: [InputCandidate]) -> [InputCandidate] {
        // Filter before allocating shortlist slots and protecting language identities.
        // Exact original input remains selectable regardless of font coverage.
        let displayable = candidates.filter { $0.isLiteral || textSupport.canDisplay($0.text) }
        return CandidateShortlist.candidates(from: displayable)
    }

    mutating func setExpanded(_ expanded: Bool) {
        guard isExpanded != expanded else { return }
        isExpanded = expanded
        firstVisibleRow = 0
        if expanded { revealSelectedRow() }
    }

    mutating func move(by offset: Int) {
        guard !candidates.isEmpty else { return }
        selectedIndex = max(0, min(candidates.count - 1, selectedIndex + offset))
        if isExpanded { revealSelectedRow() }
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
            moveRows(by: offset)
        case .page(let offset):
            movePage(by: offset)
        }
    }

    mutating func movePage(by offset: Int) {
        moveRows(by: offset * (isExpanded ? Self.expandedRowCount : 1))
    }

    private mutating func moveRows(by offset: Int) {
        guard !candidates.isEmpty else { return }
        let nextRow = max(0, min(rowCount - 1, row + offset))
        let column = selectedIndex % Self.pageSize
        move(by: nextRow * Self.pageSize + column - selectedIndex)
    }

    private mutating func revealSelectedRow() {
        let earliestStart = max(0, row - Self.expandedRowCount + 1)
        firstVisibleRow = max(earliestStart, min(firstVisibleRow, row))
    }

    func candidate(number: Int) -> InputCandidate? {
        guard (1...Self.pageSize).contains(number) else { return nil }
        let index = visibleRange.lowerBound + number - 1
        return visibleRange.contains(index) ? candidates[index] : nil
    }
}
