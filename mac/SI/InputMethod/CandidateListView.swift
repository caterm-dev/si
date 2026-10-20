import AppKit

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

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        setAccessibilityLabel("SI candidates")
        pageLabel.font = .systemFont(ofSize: 11)
        pageLabel.textColor = .secondaryLabelColor
        previousButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Previous page")
        nextButton.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Next page")
        previousButton.setAccessibilityLabel("Previous page")
        nextButton.setAccessibilityLabel("Next page")
        previousButton.toolTip = "Previous page"
        nextButton.toolTip = "Next page"
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
        layer?.cornerRadius = isExpanded ? 12 : CandidateStyle.stripHeight / 2
        let expansionLabel = isExpanded ? "Collapse candidates" : "Expand candidates"
        expandButton.image = NSImage(systemSymbolName: isExpanded ? "chevron.up" : "chevron.down",
                                     accessibilityDescription: expansionLabel)
        expandButton.setAccessibilityLabel(expansionLabel)
        expandButton.setAccessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        expandButton.toolTip = expansionLabel
        rows.forEach { $0.removeFromSuperview() }
        rows = selection.visibleRange.enumerated().map { number, index in
            let row = CandidateRowButton()
            row.configure(candidate: selection.candidates[index], number: number + 1,
                          selected: index == selection.selectedIndex, compact: !isExpanded)
            row.target = self
            row.action = #selector(selectRow(_:))
            addSubview(row)
            return row
        }
        showsPagination = selection.pageCount > 1
        pageLabel.stringValue = "\(selection.page + 1) / \(max(1, selection.pageCount))"
        pageLabel.setAccessibilityLabel("Page \(selection.page + 1) of \(max(1, selection.pageCount))")
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
        setAccessibilityHelp(isUpdating ? "Updating candidates" : nil)
    }

    var preferredSize: NSSize {
        let content: NSSize
        if !isExpanded {
            content = NSSize(width: max(160, rows.map(compactWidth).reduce(0, +) + 38), height: CandidateStyle.stripHeight)
        } else {
            let textWidth = rows.map(rowWidth).max() ?? 180
            content = NSSize(width: min(600, max(180, textWidth + 10)), height: CGFloat(rows.count) * rowHeight + 41)
        }
        return NSSize(width: max(content.width, pendingMinimumSize?.width ?? 0),
                      height: max(content.height, pendingMinimumSize?.height ?? 0))
    }

    private func rowWidth(_ row: CandidateRowButton) -> CGFloat {
        row.preferredWidth
    }

    private func compactWidth(_ row: CandidateRowButton) -> CGFloat { min(280, max(44, rowWidth(row))) }

    override func layout() {
        super.layout()
        if isExpanded {
            for (index, row) in rows.enumerated() {
                row.frame = NSRect(x: 5, y: bounds.height - 5 - CGFloat(index + 1) * rowHeight,
                                   width: bounds.width - 10, height: rowHeight)
            }
        } else {
            let available = max(0, bounds.width - 38)
            let total = max(1, rows.map(compactWidth).reduce(0, +))
            let scale = min(1, available / total)
            var x: CGFloat = 5
            for row in rows {
                let width = compactWidth(row) * scale
                row.frame = NSRect(x: x, y: (bounds.height - rowHeight) / 2, width: width, height: rowHeight)
                x += width
            }
        }
        pageLabel.frame = NSRect(x: 13, y: 7, width: max(0, bounds.width - 108), height: 16)
        previousButton.frame = NSRect(x: bounds.width - 90, y: 3, width: 26, height: 24)
        nextButton.frame = NSRect(x: bounds.width - 62, y: 3, width: 26, height: 24)
        expandButton.frame = NSRect(x: bounds.width - 32, y: isExpanded ? 3 : 4, width: 26, height: isExpanded ? 24 : rowHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        CandidateStyle.background.setFill()
        let radius: CGFloat = isExpanded ? 12 : CandidateStyle.stripHeight / 2
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        outline.fill()
        CandidateStyle.outline.setStroke()
        outline.lineWidth = 0.5
        outline.stroke()
        if !isExpanded {
            let separator = NSBezierPath()
            separator.move(to: NSPoint(x: bounds.width - 35, y: 10))
            separator.line(to: NSPoint(x: bounds.width - 35, y: bounds.height - 10))
            separator.lineWidth = 0.5
            separator.stroke()
        }
        if isExpanded {
            let separator = NSBezierPath()
            separator.move(to: NSPoint(x: 11, y: 30))
            separator.line(to: NSPoint(x: bounds.width - 11, y: 30))
            separator.lineWidth = 0.5
            separator.stroke()
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        guard !isUpdating, abs(delta) > 0.5, event.phase != .ended else { return }
        onMovePage?(delta > 0 ? -1 : 1)
    }

    @objc private func selectRow(_ sender: CandidateRowButton) {
        guard !isUpdating, rows.contains(where: { $0 === sender }) else { return }
        onSelect?(sender.candidateID)
    }
    @objc private func previousPage() { if !isUpdating { onMovePage?(-1) } }
    @objc private func nextPage() { if !isUpdating { onMovePage?(1) } }
    @objc private func toggleExpansion() { if !isUpdating { onToggleExpansion?() } }
}
