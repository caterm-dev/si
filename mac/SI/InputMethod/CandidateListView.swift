import AppKit

@MainActor
final class CandidateListView: NSView {
    private(set) var rows: [CandidateRowButton] = []
    private(set) var pageLabel = NSTextField(labelWithString: "")
    private(set) var previousButton = NSButton(title: "", target: nil, action: nil)
    private(set) var nextButton = NSButton(title: "", target: nil, action: nil)
    private(set) var showsPagination = false
    var onSelect: ((String) -> Void)?
    var onMovePage: ((Int) -> Void)?
    private let rowHeight: CGFloat = 30

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
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
        for button in [previousButton, nextButton] {
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
            button.contentTintColor = .secondaryLabelColor
            button.target = self
            addSubview(button)
        }
        previousButton.action = #selector(previousPage)
        nextButton.action = #selector(nextPage)
        addSubview(pageLabel)
    }

    required init?(coder: NSCoder) { nil }

    func render(_ selection: CandidateSelection) {
        rows.forEach { $0.removeFromSuperview() }
        rows = selection.visibleRange.enumerated().map { number, index in
            let row = CandidateRowButton()
            row.configure(candidate: selection.candidates[index], number: number + 1,
                          selected: index == selection.selectedIndex)
            row.target = self
            row.action = #selector(selectRow(_:))
            addSubview(row)
            return row
        }
        showsPagination = selection.pageCount > 1
        pageLabel.stringValue = "\(selection.page + 1) / \(max(1, selection.pageCount))"
        pageLabel.setAccessibilityLabel("Page \(selection.page + 1) of \(max(1, selection.pageCount))")
        for control in [pageLabel, previousButton, nextButton] { control.isHidden = !showsPagination }
        previousButton.isEnabled = selection.page > 0
        nextButton.isEnabled = selection.page + 1 < selection.pageCount
        needsLayout = true
        needsDisplay = true
    }

    var preferredSize: NSSize {
        let textWidth = rows.map { row in
            row.candidateLabel.intrinsicContentSize.width + 55
                + (row.detailLabel.isHidden ? 0 : min(120, row.detailLabel.intrinsicContentSize.width + 10) + 10)
        }.max() ?? 180
        return NSSize(width: min(600, max(180, textWidth)),
                      height: CGFloat(rows.count) * rowHeight + 12 + (showsPagination ? 29 : 0))
    }

    override func layout() {
        super.layout()
        for (index, row) in rows.enumerated() {
            row.frame = NSRect(x: 5, y: bounds.height - 5 - CGFloat(index + 1) * rowHeight,
                               width: bounds.width - 10, height: rowHeight)
        }
        pageLabel.frame = NSRect(x: 13, y: 7, width: max(0, bounds.width - 82), height: 16)
        previousButton.frame = NSRect(x: bounds.width - 64, y: 3, width: 26, height: 24)
        nextButton.frame = NSRect(x: bounds.width - 36, y: 3, width: 26, height: 24)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        outline.fill()
        NSColor.separatorColor.setStroke()
        outline.lineWidth = 0.5
        outline.stroke()
        if showsPagination {
            let separator = NSBezierPath()
            separator.move(to: NSPoint(x: 11, y: 30))
            separator.line(to: NSPoint(x: bounds.width - 11, y: 30))
            separator.lineWidth = 0.5
            separator.stroke()
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard abs(event.scrollingDeltaY) > 0.5, event.phase != .ended else { return }
        onMovePage?(event.scrollingDeltaY > 0 ? -1 : 1)
    }

    @objc private func selectRow(_ sender: CandidateRowButton) { onSelect?(sender.candidateID) }
    @objc private func previousPage() { onMovePage?(-1) }
    @objc private func nextPage() { onMovePage?(1) }
}
