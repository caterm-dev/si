import AppKit
#if SWIFT_PACKAGE
import SILocalization
#endif

@MainActor
final class CandidateListView: NSView {
    private(set) var rows: [CandidateRowButton] = []
    private var renderedRange = 0..<0
    private(set) var expandButton = NSButton(title: "", target: nil, action: nil)
    private(set) var isExpanded = false
    var onSelect: ((String) -> Void)?
    var onSelectPrediction: (() -> Void)?
    let predictionButton = NSButton(title: "", target: nil, action: nil)
    private var predictionHeight: CGFloat { predictionButton.isHidden ? 0 : rowHeight + 6 }
    var onToggleExpansion: (() -> Void)?
    private let rowHeight = CandidateStyle.rowHeight
    private var keyboardLine = 0
    private var columnsPerRow = CandidateSelection.pageSize
    private let measurementRow = CandidateRowButton()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        setAccessibilityLabel(L10n.text("SI candidates"))
        expandButton.isBordered = false
        expandButton.imagePosition = .imageOnly
        expandButton.symbolConfiguration = .init(pointSize: 9, weight: .medium)
        expandButton.contentTintColor = .secondaryLabelColor
        expandButton.target = self
        expandButton.action = #selector(toggleExpansion)
        addSubview(expandButton)
        predictionButton.target = self
        predictionButton.action = #selector(selectPrediction)
        predictionButton.isBordered = false
        predictionButton.alignment = .left
        predictionButton.font = .systemFont(ofSize: 13)
        (predictionButton.cell as? NSButtonCell)?.lineBreakMode = .byTruncatingTail
        predictionButton.isHidden = true
        addSubview(predictionButton)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    func render(_ selection: CandidateSelection, prediction: String? = nil, predictionStatus: String? = nil) {
        predictionButton.isHidden = prediction == nil && predictionStatus == nil
        predictionButton.isEnabled = prediction != nil
        if let prediction, !predictionButton.isHidden {
            predictionButton.title = L10n.format("AI · Tab   %@", prediction)
            predictionButton.toolTip = prediction
            predictionButton.setAccessibilityLabel(L10n.format("AI completion: %@", prediction))
            predictionButton.setAccessibilityHelp(L10n.text("Press Tab to accept AI completion"))
        } else if let predictionStatus {
            predictionButton.title = L10n.format("AI · %@", predictionStatus)
            predictionButton.toolTip = predictionStatus
            predictionButton.setAccessibilityLabel(predictionButton.title)
            predictionButton.setAccessibilityHelp(nil)
        } else {
            predictionButton.title = ""
            predictionButton.toolTip = nil
            predictionButton.setAccessibilityLabel(nil)
            predictionButton.setAccessibilityHelp(nil)
        }
        columnsPerRow = selection.visiblePageSize
        let visible = selection.displayedRange
        keyboardLine = (selection.visibleRange.lowerBound - visible.lowerBound) / selection.visiblePageSize
        isExpanded = selection.isExpanded
        layer?.cornerRadius = cardRadius
        let expansionLabel = L10n.text(isExpanded ? "Collapse candidates" : "Expand candidates")
        expandButton.image = NSImage(systemSymbolName: isExpanded ? "chevron.up" : "chevron.down",
                                     accessibilityDescription: expansionLabel)
        expandButton.setAccessibilityLabel(expansionLabel)
        expandButton.setAccessibilityValue(L10n.text(isExpanded ? "Expanded" : "Collapsed"))
        expandButton.toolTip = !isExpanded ? "\(expansionLabel) (↓)" : expansionLabel
        let presented = selection.candidates
        let canReuse = renderedRange == visible && zip(rows, visible).allSatisfy {
            $0.0.candidateID == presented[$0.1].id
        }
        if !canReuse {
            var previousRows = Dictionary(uniqueKeysWithValues: zip(renderedRange, rows))
            rows = visible.map { index in
                if let previous = previousRows[index], previous.candidateID == presented[index].id {
                    previousRows.removeValue(forKey: index)
                    return previous
                }
                let row = CandidateRowButton()
                row.target = self
                row.action = #selector(selectRow(_:))
                addSubview(row)
                return row
            }
            previousRows.values.forEach { $0.removeFromSuperview() }
            renderedRange = visible
        }
        for (number, index) in visible.enumerated() {
            let row = rows[number]
            row.configure(candidate: presented[index], number: index % selection.visiblePageSize + 1,
                          selected: index == selection.selectedIndex, compact: true,
                          keyboardRow: selection.visibleRange.contains(index))
            let column = index % selection.visiblePageSize + 1
            if isExpanded {
                row.setAccessibilityHelp(L10n.format("Row %ld, column %ld", index / selection.visiblePageSize + 1, column))
            } else {
                let page = L10n.format("Page %ld of %ld", selection.row + 1, selection.rowCount)
                let cell = L10n.format("Row %ld, column %ld", 1, column)
                row.setAccessibilityHelp("\(page) · \(cell)")
            }
        }
        expandButton.isHidden = rows.isEmpty
        expandButton.isEnabled = !rows.isEmpty
        var accessibilityViews = (rows as [NSView]) + [expandButton]
        if !predictionButton.isHidden { accessibilityViews.append(predictionButton) }
        setAccessibilityChildren(accessibilityViews)
        needsLayout = true
        needsDisplay = true
    }

    /// Reduce columns before truncating a single oversized candidate. Measure the
    /// same compact buttons and expanded viewport that will actually be displayed.
    func fittingPageSize(for selection: CandidateSelection, maximumWidth: CGFloat) -> Int {
        var measured: [Int: CGFloat] = [:]
        for count in stride(from: CandidateSelection.pageSize, through: 1, by: -1) {
            var trial = selection
            trial.setPageSize(count)
            var widths = Array(repeating: CGFloat(44), count: min(count, trial.displayedRange.count))
            for index in trial.displayedRange {
                let width: CGFloat
                if let cached = measured[index] { width = cached }
                else {
                    measurementRow.configure(candidate: trial.candidates[index], number: index % count + 1,
                                             selected: false, compact: true)
                    width = measurementRow.preferredWidth
                    measured[index] = width
                }
                widths[index % count] = max(widths[index % count], width)
            }
            // Candidate cells plus the existing outer insets and expansion control.
            if widths.reduce(0, +) + 38 <= maximumWidth { return count }
        }
        return 1
    }

    private var cardRadius: CGFloat {
        isExpanded || !predictionButton.isHidden ? 12 : CandidateStyle.stripHeight / 2
    }

    var preferredSize: NSSize {
        preferredSize(constrainedTo: .greatestFiniteMagnitude)
    }

    func preferredSize(constrainedTo maximumWidth: CGFloat) -> NSSize {
        let predictionWidth = predictionButton.isHidden ? 0 : min(540, predictionButton.fittingSize.width + 22)
        let naturalWidth = max(160, naturalColumnWidths.reduce(0, +) + 38, predictionWidth)
        let width = min(max(1, maximumWidth), naturalWidth)
        let lines = isExpanded ? max(1, (rows.count + columnsPerRow - 1) / columnsPerRow) : 1
        let contentHeight = CGFloat(lines) * (rowHeight + 4) + 4
        return NSSize(width: width, height: contentHeight + predictionHeight)
    }

    private var naturalColumnWidths: [CGFloat] {
        let count = min(rows.count, columnsPerRow)
        var widths = Array(repeating: CGFloat(44), count: count)
        // Every visible row shares its column's widest text, number and source hint.
        for (index, row) in rows.enumerated() {
            widths[index % columnsPerRow] = max(widths[index % columnsPerRow], row.preferredWidth)
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
        for start in stride(from: 0, to: rows.count, by: columnsPerRow) {
            var x: CGFloat = 5
            for column in 0..<min(columnsPerRow, rows.count - start) {
                cells.append((x: x, width: columns[column], line: start / columnsPerRow))
                x += columns[column]
            }
        }
        return cells
    }

    override func layout() {
        super.layout()
        let predictionOffset = predictionHeight
        predictionButton.frame = NSRect(x: 11, y: 3, width: max(0, bounds.width - 22), height: rowHeight)
        if isExpanded {
            for (row, cell) in zip(rows, gridCells(width: bounds.width)) {
                row.frame = NSRect(x: cell.x, y: bounds.height - 4 - rowHeight - CGFloat(cell.line) * (rowHeight + 4),
                                   width: cell.width, height: rowHeight)
            }
        } else {
            let available = max(0, bounds.width - 38)
            var x: CGFloat = 5
            for (row, width) in zip(rows, cellWidths(naturalColumnWidths, available: available)) {
                row.frame = NSRect(x: x, y: (bounds.height + predictionOffset - rowHeight) / 2,
                                   width: width, height: rowHeight)
                x += width
            }
        }
        expandButton.frame = NSRect(x: bounds.width - 32, y: bounds.height - 32,
                                   width: 26, height: rowHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        CandidateStyle.background.setFill()
        let radius = cardRadius
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        outline.fill()
        CandidateStyle.outline.setStroke()
        outline.lineWidth = 0.5
        outline.stroke()
        if isExpanded, !rows.isEmpty {
            CandidateStyle.activeRow.setFill()
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
        if !predictionButton.isHidden {
            drawHorizontalSeparator(at: predictionHeight)
        }
    }

    private func drawHorizontalSeparator(at height: CGFloat) {
        let separator = NSBezierPath()
        separator.move(to: NSPoint(x: 11, y: height))
        separator.line(to: NSPoint(x: bounds.width - 11, y: height))
        separator.lineWidth = 0.5
        CandidateStyle.outline.setStroke()
        separator.stroke()
    }

    override func scrollWheel(with event: NSEvent) {
        // Candidate navigation is driven by keys and clicks.
    }

    @objc private func selectRow(_ sender: CandidateRowButton) {
        guard rows.contains(where: { $0 === sender }) else { return }
        onSelect?(sender.candidateID)
    }
    @objc private func selectPrediction() {
        if !predictionButton.isHidden, predictionButton.isEnabled { onSelectPrediction?() }
    }
    @objc private func toggleExpansion() { if expandButton.isEnabled { onToggleExpansion?() } }
}
