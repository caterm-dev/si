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
    private(set) var candidates: [InputCandidate] = []
    private(set) var selectedIndex = 0

    var selected: InputCandidate? { candidates.indices.contains(selectedIndex) ? candidates[selectedIndex] : nil }
    var page: Int { selectedIndex / Self.pageSize }
    var pageCount: Int { (candidates.count + Self.pageSize - 1) / Self.pageSize }
    var visibleRange: Range<Int> {
        let start = page * Self.pageSize
        return start..<min(start + Self.pageSize, candidates.count)
    }

    static func action(keyCode: UInt16, characters: String?) -> Action? {
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

    mutating func update(_ candidates: [InputCandidate]) {
        self.candidates = candidates
        selectedIndex = 0
    }

    mutating func move(by offset: Int) {
        guard !candidates.isEmpty else { return }
        selectedIndex = max(0, min(candidates.count - 1, selectedIndex + offset))
    }

    mutating func movePage(by offset: Int) { move(by: offset * Self.pageSize) }

    func candidate(number: Int) -> InputCandidate? {
        guard (1...Self.pageSize).contains(number) else { return nil }
        let index = page * Self.pageSize + number - 1
        return visibleRange.contains(index) ? candidates[index] : nil
    }
}
