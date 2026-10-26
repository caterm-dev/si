import AppKit
#if SWIFT_PACKAGE
import SILocalization
#endif

@MainActor
final class CandidateListView: NSView {
    private(set) var rows: [CandidateRowButton] = []
    private(set) var pageLabel = NSTextField(labelWithString: "")
    private(set) var previousButton = NSButton(title: "", target: nil, action: nil)
    private(set) var nextButton = NSButton(title: "", target: nil, action: nil)
    private(set) var expandButton = NSButton(title: "", target: nil, action: nil)
    private(set) var isExpanded = false
    private(set) var showsPagination = false
    private(set) var isUpdating = false
    var onSelect: ((String) -> Void)?
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
        keyboardLine = selection.row
        layer?.cornerRadius = isExpanded ? 12 : CandidateStyle.stripHeight / 2
        let expansionLabel = L10n.text(isExpanded ? "Collapse candidates" : "Expand candidates")
        expandButton.image = NSImage(systemSymbolName: isExpanded ? "chevron.up" : "chevron.down",
                                     accessibilityDescription: expansionLabel)
        expandButton.setAccessibilityLabel(expansionLabel)
        expandButton.setAccessibilityValue(L10n.text(isExpanded ? "Expanded" : "Collapsed"))
        expandButton.toolTip = isExpanded ? expansionLabel : "\(expansionLabel) (↓)"
        let visible = Array(selection.displayedRange)
        let canReuse = rows.count == visible.count && zip(rows, visible).allSatisfy {
            $0.0.candidateID == selection.candidates[$0.1].id
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
            row.configure(candidate: selection.candidates[index], number: index % selection.visiblePageSize + 1,
                          selected: index == selection.selectedIndex, compact: true,
                          keyboardRow: selection.visibleRange.contains(index))
            let page = L10n.format("Page %ld of %ld", selection.page + 1, selection.pageCount)
            let cell = L10n.format("Row %ld, column %ld", (index - selection.displayedRange.lowerBound) / selection.visiblePageSize + 1,
                                   index % selection.visiblePageSize + 1)
            row.setAccessibilityHelp("\(page) · \(cell)")
        }
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
        previousButton.isEnabled = !isUpdating && selection.page > 0
        nextButton.isEnabled = !isUpdating && selection.page + 1 < selection.pageCount
        expandButton.isEnabled = !isUpdating
        setAccessibilityHelp(isUpdating ? L10n.text("Updating candidates") : nil)
    }

    var preferredSize: NSSize {
        preferredSize(constrainedTo: .greatestFiniteMagnitude)
    }

    func preferredSize(constrainedTo maximumWidth: CGFloat) -> NSSize {
        // Expansion preserves the compact strip's first six cells and width.
        let naturalWidth = max(160, rows.prefix(CandidateSelection.compactPageSize).map(compactWidth).reduce(0, +) + 38)
        let width = min(max(1, maximumWidth), max(naturalWidth, pendingMinimumSize?.width ?? 0))
        let lines = isExpanded ? max(1, (rows.count + CandidateSelection.pageSize - 1) / CandidateSelection.pageSize) : 1
        let contentHeight = CGFloat(lines) * (rowHeight + 4) + 4
        let footer: CGFloat = isExpanded && showsPagination ? 30 : 0
        return NSSize(width: width, height: max(contentHeight + footer, pendingMinimumSize?.height ?? 0))
    }

    private func rowWidth(_ row: CandidateRowButton) -> CGFloat {
        row.preferredWidth
    }

    private func compactWidth(_ row: CandidateRowButton) -> CGFloat { min(280, max(44, rowWidth(row))) }

    private func cellWidths(_ line: [CandidateRowButton], available: CGFloat) -> [CGFloat] {
        let natural = line.map(compactWidth)
        let total = natural.reduce(0, +)
        guard total > available, !line.isEmpty else { return natural }
        // Keep a number and glyph available before sharing the remaining width.
        let minimum = min(44, available / CGFloat(line.count))
        let extra = max(0, available - minimum * CGFloat(line.count))
        let flexible = max(1, total - minimum * CGFloat(line.count))
        return natural.map { minimum + ($0 - minimum) * extra / flexible }
    }

    private func gridCells(width: CGFloat) -> [(x: CGFloat, width: CGFloat, line: Int)] {
        let available = max(0, width - 38)
        let columns = cellWidths(Array(rows.prefix(CandidateSelection.pageSize)), available: available)
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
            for (row, width) in zip(rows, cellWidths(rows, available: available)) {
                row.frame = NSRect(x: x, y: (bounds.height - rowHeight) / 2, width: width, height: rowHeight)
                x += width
            }
        }
        pageLabel.frame = NSRect(x: 13, y: 7, width: max(0, bounds.width - 108), height: 16)
        previousButton.frame = NSRect(x: bounds.width - 90, y: 3, width: 26, height: 24)
        nextButton.frame = NSRect(x: bounds.width - 62, y: 3, width: 26, height: 24)
        expandButton.frame = NSRect(x: bounds.width - 32, y: bounds.height - 32, width: 26, height: rowHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        CandidateStyle.background.setFill()
        let radius: CGFloat = isExpanded ? 12 : CandidateStyle.stripHeight / 2
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        outline.fill()
        CandidateStyle.outline.setStroke()
        outline.lineWidth = 0.5
        outline.stroke()
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
        onSelect?(sender.candidateID)
    }
    @objc private func previousPage() { if !isUpdating { onMovePage?(-1) } }
    @objc private func nextPage() { if !isUpdating { onMovePage?(1) } }
    @objc private func toggleExpansion() { if !isUpdating { onToggleExpansion?() } }
}
