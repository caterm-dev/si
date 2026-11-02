import AppKit
#if SWIFT_PACKAGE
import SILocalization
#endif

@MainActor
final class CandidateListView: NSView {
    private(set) var rows: [CandidateRowButton] = []
    private(set) var comparisonRows: [CandidateRowButton] = []
    private(set) var comparisonLabel = NSTextField(labelWithString: "")
    private(set) var aiButton = NSButton(title: "AI", target: nil, action: nil)
    private var comparisonState = CandidateSelection.ComparisonState.disabled
    private var activeRanking = CandidateSelection.Ranking.base
    private var showsComparison: Bool { !isExpanded && comparisonState != .disabled }
    private let comparisonRowHeight: CGFloat = 44
    private(set) var pageLabel = NSTextField(labelWithString: "")
    private(set) var previousButton = NSButton(title: "", target: nil, action: nil)
    private(set) var nextButton = NSButton(title: "", target: nil, action: nil)
    private(set) var expandButton = NSButton(title: "", target: nil, action: nil)
    private(set) var isExpanded = false
    private(set) var showsPagination = false
    private(set) var isUpdating = false
    var onSelect: ((String) -> Void)?
    var onSelectRanking: ((String, CandidateSelection.Ranking) -> Void)?
    var onChangeRanking: ((CandidateSelection.Ranking) -> Void)?
    var onMovePage: ((Int) -> Void)?
    var onToggleExpansion: (() -> Void)?
    private let rowHeight = CandidateStyle.rowHeight
    private var pendingMinimumSize: NSSize?
    private var keyboardLine = 0

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        setAccessibilityLabel(L10n.text("SI candidates"))
        pageLabel.font = .systemFont(ofSize: 11)
        pageLabel.textColor = .secondaryLabelColor
        previousButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: L10n.text("Previous page"))
        nextButton.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: L10n.text("Next page"))
        previousButton.setAccessibilityLabel(L10n.text("Previous page"))
        nextButton.setAccessibilityLabel(L10n.text("Next page"))
        previousButton.toolTip = L10n.text("Previous page")
        nextButton.toolTip = L10n.text("Next page")
        for button in [previousButton, nextButton, expandButton] {
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.symbolConfiguration = .init(pointSize: 9, weight: .medium)
            button.contentTintColor = .secondaryLabelColor
            button.target = self
            addSubview(button)
        }
        previousButton.action = #selector(previousPage)
        nextButton.action = #selector(nextPage)
        expandButton.action = #selector(toggleExpansion)
        addSubview(pageLabel)
        comparisonLabel.font = .systemFont(ofSize: 11)
        comparisonLabel.textColor = .secondaryLabelColor
        addSubview(comparisonLabel)
        aiButton.isBordered = false
        aiButton.font = .systemFont(ofSize: 9, weight: .semibold)
        aiButton.contentTintColor = CandidateStyle.accent
        aiButton.target = self
        aiButton.action = #selector(changeRanking)
        aiButton.setAccessibilityLabel(L10n.text("Select AI ranking"))
        aiButton.toolTip = L10n.text("Select AI ranking")
        addSubview(aiButton)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    func render(_ selection: CandidateSelection, isPending: Bool = false, refreshPendingRows: Bool = false) {
        if !isPending { pendingMinimumSize = nil }
        else if !rows.isEmpty { pendingMinimumSize = preferredSize }
        isUpdating = isPending
        // Keep the current card intact while a newer composition is being searched.
        // These rows are only a visual placeholder; they cannot confirm stale text.
        if isPending, !refreshPendingRows, !rows.isEmpty {
            updateInteraction(selection)
            return
        }
        isExpanded = selection.isExpanded
        comparisonState = selection.comparisonState
        activeRanking = selection.ranking
        keyboardLine = selection.row
        layer?.cornerRadius = isExpanded || showsComparison ? 12 : CandidateStyle.stripHeight / 2
        let expansionLabel = L10n.text(isExpanded ? "Collapse candidates" : "Expand candidates")
        expandButton.image = NSImage(systemSymbolName: isExpanded ? "chevron.up" : "chevron.down",
                                     accessibilityDescription: expansionLabel)
        expandButton.setAccessibilityLabel(expansionLabel)
        expandButton.setAccessibilityValue(L10n.text(isExpanded ? "Expanded" : "Collapsed"))
        expandButton.toolTip = isExpanded ? expansionLabel : "\(expansionLabel) (↓)"
        let presented = isExpanded ? selection.candidates : selection.candidates(for: .base)
        let start = min(selection.page * selection.pageCapacity, max(0, presented.count - 1) / 6 * 6)
        let visible = Array(start..<min(start + selection.pageCapacity, presented.count))
        let canReuse = rows.count == visible.count && zip(rows, visible).allSatisfy {
            $0.0.candidateID == presented[$0.1].id
        }
        if !canReuse {
            rows.forEach { $0.removeFromSuperview() }
            rows = visible.map { _ in
                let row = CandidateRowButton()
                row.target = self
                row.action = #selector(selectRow(_:))
                addSubview(row)
                return row
            }
        }
        for (number, index) in visible.enumerated() {
            let row = rows[number]
            row.configure(candidate: presented[index], number: index % selection.visiblePageSize + 1,
                          selected: index == selection.selectedIndex && (isExpanded || activeRanking == .base), compact: true,
                          keyboardRow: (isExpanded || activeRanking == .base) && selection.visibleRange.contains(index))
            let page = L10n.format("Page %ld of %ld", selection.page + 1, selection.pageCount)
            let cell = L10n.format("Row %ld, column %ld", (index - selection.displayedRange.lowerBound) / selection.visiblePageSize + 1,
                                   index % selection.visiblePageSize + 1)
            row.setAccessibilityHelp("\(page) · \(cell)")
        }
        renderComparison(selection)
        showsPagination = selection.pageCount > 1
        pageLabel.stringValue = "\(selection.page + 1) / \(max(1, selection.pageCount))"
        pageLabel.setAccessibilityLabel(L10n.format("Page %ld of %ld", selection.page + 1, max(1, selection.pageCount)))
        for control in [pageLabel, previousButton, nextButton] { control.isHidden = !isExpanded || !showsPagination }
        expandButton.isHidden = rows.isEmpty
        updateInteraction(selection)
        needsLayout = true
        needsDisplay = true
    }

    private func updateInteraction(_ selection: CandidateSelection) {
        rows.forEach { $0.isEnabled = !isUpdating }
        comparisonRows.forEach { $0.isEnabled = !isUpdating && selection.canSelectAI }
        aiButton.isEnabled = !isUpdating && selection.canSelectAI
        previousButton.isEnabled = !isUpdating && selection.page > 0
        nextButton.isEnabled = !isUpdating && selection.page + 1 < selection.pageCount
        expandButton.isEnabled = !isUpdating
        setAccessibilityHelp(isUpdating ? L10n.text("Updating candidates") : nil)
    }

    private func renderComparison(_ selection: CandidateSelection) {
        comparisonRows.forEach { $0.removeFromSuperview() }
        comparisonRows = []
        aiButton.isHidden = !showsComparison
        let rankingAction = L10n.text(activeRanking == .ai ? "Select original ranking" : "Select AI ranking")
        aiButton.setAccessibilityLabel(rankingAction)
        aiButton.setAccessibilityValue(activeRanking == .ai ? L10n.text("Selected") : "")
        aiButton.toolTip = rankingAction
        comparisonLabel.isHidden = !showsComparison || selection.canSelectAI
        switch comparisonState {
        case .loading: comparisonLabel.stringValue = L10n.text("AI is scoring candidates…")
        case .unavailable: comparisonLabel.stringValue = L10n.text("AI unavailable — original ranking remains active")
        default: comparisonLabel.stringValue = ""
        }
        guard showsComparison, selection.canSelectAI else { return }
        let candidates = selection.candidates(for: .ai)
        let start = min(selection.page * 6, max(0, candidates.count - 1) / 6 * 6)
        comparisonRows = (start..<min(start + 6, candidates.count)).map { index in
            let row = CandidateRowButton()
            let candidate = candidates[index]
            row.configure(candidate: candidate, number: index % 6 + 1,
                          selected: activeRanking == .ai && index == selection.selectedIndex, compact: true,
                          keyboardRow: activeRanking == .ai, aiScore: selection.fusion?.scores[candidate.id])
            row.setAccessibilityHelp(L10n.text("AI ranking"))
            row.target = self
            row.action = #selector(selectComparison(_:))
            addSubview(row)
            return row
        }
    }

    var preferredSize: NSSize {
        preferredSize(constrainedTo: .greatestFiniteMagnitude)
    }

    func preferredSize(constrainedTo maximumWidth: CGFloat) -> NSSize {
        let naturalWidth = max(160, naturalColumnWidths.reduce(0, +) + 38)
        let width = min(max(1, maximumWidth), max(naturalWidth, pendingMinimumSize?.width ?? 0))
        let lines = isExpanded ? max(1, (rows.count + CandidateSelection.pageSize - 1) / CandidateSelection.pageSize) : 1
        let contentHeight = CGFloat(lines) * (rowHeight + 4) + 4 + (showsComparison ? comparisonRowHeight + 5 : 0)
        let footer: CGFloat = isExpanded && showsPagination ? 30 : 0
        return NSSize(width: width, height: max(contentHeight + footer, pendingMinimumSize?.height ?? 0))
    }

    private var naturalColumnWidths: [CGFloat] {
        let count = min(rows.count, CandidateSelection.pageSize)
        var widths = Array(repeating: CGFloat(44), count: count)
        // Every visible row shares its column's widest text, number and source hint.
        for (index, row) in rows.enumerated() {
            widths[index % CandidateSelection.pageSize] = max(widths[index % CandidateSelection.pageSize], row.preferredWidth)
        }
        for (index, row) in comparisonRows.enumerated() where index < widths.count {
            widths[index] = max(widths[index], row.preferredWidth)
        }
        if showsComparison, comparisonRows.isEmpty, !widths.isEmpty {
            // Keep the loading/error message readable without inventing AI candidates.
            widths[0] = max(widths[0], 260)
        }
        return widths
    }

    private func cellWidths(_ natural: [CGFloat], available: CGFloat) -> [CGFloat] {
        let total = natural.reduce(0, +)
        guard total > available, !natural.isEmpty else { return natural }
        // Keep a number and glyph available before sharing the remaining width.
        let minimum = min(44, available / CGFloat(natural.count))
        let extra = max(0, available - minimum * CGFloat(natural.count))
        let flexible = max(1, total - minimum * CGFloat(natural.count))
        return natural.map { minimum + ($0 - minimum) * extra / flexible }
    }

    private func gridCells(width: CGFloat) -> [(x: CGFloat, width: CGFloat, line: Int)] {
        let available = max(0, width - 38)
        let columns = cellWidths(naturalColumnWidths, available: available)
        var cells: [(x: CGFloat, width: CGFloat, line: Int)] = []
        for start in stride(from: 0, to: rows.count, by: CandidateSelection.pageSize) {
            var x: CGFloat = 5
            for column in 0..<min(CandidateSelection.pageSize, rows.count - start) {
                cells.append((x: x, width: columns[column], line: start / CandidateSelection.pageSize))
                x += columns[column]
            }
        }
        return cells
    }

    override func layout() {
        super.layout()
        if isExpanded {
            for (row, cell) in zip(rows, gridCells(width: bounds.width)) {
                row.frame = NSRect(x: cell.x, y: bounds.height - 4 - rowHeight - CGFloat(cell.line) * (rowHeight + 4),
                                   width: cell.width, height: rowHeight)
            }
        } else {
            let available = max(0, bounds.width - 38)
            var x: CGFloat = 5
            for (row, width) in zip(rows, cellWidths(naturalColumnWidths, available: available)) {
                row.frame = NSRect(x: x, y: showsComparison ? bounds.height - 4 - rowHeight : (bounds.height - rowHeight) / 2,
                                   width: width, height: rowHeight)
                x += width
            }
            x = 5
            for (row, width) in zip(comparisonRows, cellWidths(naturalColumnWidths, available: available)) {
                row.frame = NSRect(x: x, y: 4, width: width, height: comparisonRowHeight)
                x += width
            }
        }
        comparisonLabel.frame = NSRect(x: 14, y: 16, width: max(0, bounds.width - 54), height: 18)
        aiButton.frame = NSRect(x: bounds.width - 32, y: 12, width: 26, height: 24)
        pageLabel.frame = NSRect(x: 13, y: 7, width: max(0, bounds.width - 108), height: 16)
        previousButton.frame = NSRect(x: bounds.width - 90, y: 3, width: 26, height: 24)
        nextButton.frame = NSRect(x: bounds.width - 62, y: 3, width: 26, height: 24)
        expandButton.frame = NSRect(x: bounds.width - 32, y: bounds.height - 32, width: 26, height: rowHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        CandidateStyle.background.setFill()
        let radius: CGFloat = isExpanded || showsComparison ? 12 : CandidateStyle.stripHeight / 2
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        outline.fill()
        CandidateStyle.outline.setStroke()
        outline.lineWidth = 0.5
        outline.stroke()
        if showsComparison {
            let divider = NSBezierPath()
            divider.move(to: NSPoint(x: 11, y: comparisonRowHeight + 6))
            divider.line(to: NSPoint(x: bounds.width - 11, y: comparisonRowHeight + 6))
            divider.lineWidth = 0.5
            divider.stroke()
        }
        if isExpanded, !rows.isEmpty {
            CandidateStyle.selection.withAlphaComponent(0.25).setFill()
            let line = NSRect(x: 5, y: bounds.height - 4 - rowHeight - CGFloat(keyboardLine) * (rowHeight + 4),
                              width: max(0, bounds.width - 38), height: rowHeight)
            NSBezierPath(roundedRect: line, xRadius: 8, yRadius: 8).fill()
        }
        if !rows.isEmpty {
            let separator = NSBezierPath()
            separator.move(to: NSPoint(x: bounds.width - 35, y: bounds.height - 26))
            separator.line(to: NSPoint(x: bounds.width - 35, y: bounds.height - 10))
            separator.lineWidth = 0.5
            separator.stroke()
        }
        if isExpanded && showsPagination {
            let separator = NSBezierPath()
            separator.move(to: NSPoint(x: 11, y: 30))
            separator.line(to: NSPoint(x: bounds.width - 11, y: 30))
            separator.lineWidth = 0.5
            separator.stroke()
        }
    }

    override func scrollWheel(with event: NSEvent) {
        // Wheel and trackpad gestures must not change the candidate page or selection.
    }

    @objc private func selectRow(_ sender: CandidateRowButton) {
        guard !isUpdating, rows.contains(where: { $0 === sender }) else { return }
        if let onSelectRanking { onSelectRanking(sender.candidateID, isExpanded ? activeRanking : .base) }
        else { onSelect?(sender.candidateID) }
    }
    @objc private func selectComparison(_ sender: CandidateRowButton) {
        guard !isUpdating, comparisonState == .ready, comparisonRows.contains(where: { $0 === sender }) else { return }
        onSelectRanking?(sender.candidateID, .ai)
    }
    @objc private func changeRanking() {
        guard !isUpdating, comparisonState == .ready else { return }
        onChangeRanking?(activeRanking == .ai ? .base : .ai)
    }
    @objc private func previousPage() { if !isUpdating { onMovePage?(-1) } }
    @objc private func nextPage() { if !isUpdating { onMovePage?(1) } }
    @objc private func toggleExpansion() { if !isUpdating { onToggleExpansion?() } }
}
