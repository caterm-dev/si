import AppKit
#if SWIFT_PACKAGE
import SICore
#endif

@MainActor
final class CandidateRowButton: NSButton {
    let numberLabel = NSTextField(labelWithString: "")
    let candidateLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(labelWithString: "")
    private(set) var candidateID = ""
    private(set) var isCurrent = false

    override var acceptsFirstResponder: Bool { false }

    init() {
        super.init(frame: .zero)
        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        numberLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        candidateLabel.font = .systemFont(ofSize: 16)
        detailLabel.font = .systemFont(ofSize: 10)
        for label in [numberLabel, candidateLabel, detailLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.setAccessibilityElement(false)
            addSubview(label)
        }
    }

    required init?(coder: NSCoder) { nil }

    func configure(candidate: InputCandidate, number: Int, selected: Bool) {
        candidateID = candidate.id
        isCurrent = selected
        numberLabel.stringValue = String(number)
        candidateLabel.stringValue = candidate.text
        // Only actionable distinctions take visible space; language identity stays in AX/tooltips.
        var details: [String] = []
        if let count = candidate.consumedInputCount { details.append("First \(count)") }
        if candidate.isLiteral { details.append("As Typed") }
        else if candidate.isUserPhrase { details.append("Personal") }
        else if candidate.hasLiteralSegments { details.append("Typed text") }
        detailLabel.stringValue = details.joined(separator: " · ")
        detailLabel.isHidden = details.isEmpty
        toolTip = "\(candidate.text) — \(candidate.label)"
        setAccessibilityLabel("\(number), \(candidate.text), \(candidate.label)")
        setAccessibilityValue(selected ? "Selected" : "")
        candidateLabel.textColor = selected ? .alternateSelectedControlTextColor : .labelColor
        numberLabel.textColor = selected ? .alternateSelectedControlTextColor : .secondaryLabelColor
        detailLabel.textColor = selected ? .alternateSelectedControlTextColor : .secondaryLabelColor
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let detailWidth = detailLabel.isHidden ? 0 : min(120, max(0, bounds.width - 80), detailLabel.intrinsicContentSize.width + 10)
        numberLabel.frame = NSRect(x: 9, y: (bounds.height - 16) / 2, width: 18, height: 16)
        detailLabel.frame = NSRect(x: bounds.width - detailWidth - 10, y: (bounds.height - 15) / 2,
                                   width: detailWidth, height: 15)
        let trailing = detailWidth > 0 ? detailWidth + 20 : 10
        candidateLabel.frame = NSRect(x: 31, y: (bounds.height - 23) / 2,
                                      width: max(0, bounds.width - 31 - trailing), height: 23)
    }

    override func draw(_ dirtyRect: NSRect) {
        if isCurrent {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
    }

    // Labels must not take mouse events away from the row's button action.
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
}
