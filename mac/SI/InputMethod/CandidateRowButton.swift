import AppKit
#if SWIFT_PACKAGE
import SICore
#endif

@MainActor
final class CandidateRowButton: NSButton {
    let numberLabel = NSTextField(labelWithString: "")
    let candidateLabel = NSTextField(labelWithString: "")
    let detailLabel = CandidateBadgeLabel(labelWithString: "")
    let sourceIndicator = NSImageView()
    private(set) var candidateID = ""
    private(set) var isCurrent = false
    private(set) var isCompact = false
    private var configuredCandidate: InputCandidate?
    private var usesBadge = false

    override var acceptsFirstResponder: Bool { false }

    init() {
        super.init(frame: .zero)
        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        numberLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        candidateLabel.font = .systemFont(ofSize: 15)
        detailLabel.font = .systemFont(ofSize: 9)
        for label in [numberLabel, candidateLabel, detailLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.setAccessibilityElement(false)
            addSubview(label)
        }
        sourceIndicator.symbolConfiguration = .init(pointSize: 8, weight: .medium)
        sourceIndicator.contentTintColor = .tertiaryLabelColor
        sourceIndicator.setAccessibilityElement(false)
        addSubview(sourceIndicator)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    func configure(candidate: InputCandidate, number: Int, selected: Bool, compact: Bool = false) {
        if let previous = configuredCandidate, previous == candidate,
           previous.text.utf8.elementsEqual(candidate.text.utf8),
           numberLabel.stringValue == String(number), isCurrent == selected, isCompact == compact { return }
        configuredCandidate = candidate
        candidateID = candidate.id
        isCurrent = selected
        isCompact = compact
        numberLabel.stringValue = String(number)
        candidateLabel.stringValue = candidate.text
        // Punctuation needs a visible language hint even in the compact strip.
        let showsPunctuation = candidate.punctuationLanguage != nil
            || (candidate.isLiteral && PunctuationCandidates.hasRecognizedSuffix(candidate.text))
        usesBadge = showsPunctuation
        var details: [String] = []
        if let language = candidate.punctuationLanguage { details.append(language == .english ? "E" : "C") }
        else if candidate.isHistory { details.append("App History") }
        else if candidate.isApplicationVocabulary { details.append("App Vocabulary") }
        else if candidate.isLiteral { details.append(usesBadge ? "A" : "As Typed") }
        else if candidate.isUserPhrase { details.append("Personal") }
        else if candidate.hasLiteralSegments { details.append("Typed text") }
        detailLabel.stringValue = details.joined(separator: " · ")
        detailLabel.isHidden = details.isEmpty || (compact && !showsPunctuation)
        detailLabel.centersBadgeGlyph = usesBadge
        detailLabel.font = .systemFont(ofSize: usesBadge ? 8 : 9, weight: usesBadge ? .medium : .regular)
        candidateLabel.alignment = .left
        detailLabel.alignment = usesBadge ? .center : .left
        let symbol: String?
        if candidate.isHistory { symbol = "clock.arrow.circlepath" }
        else if candidate.isApplicationVocabulary { symbol = "app.badge" }
        else if candidate.isPartial { symbol = "arrow.right" }
        else if candidate.isLiteral { symbol = "textformat" }
        else if candidate.isUserPhrase { symbol = "pin.fill" }
        else if candidate.hasLiteralSegments { symbol = "ellipsis" }
        else { symbol = nil }
        sourceIndicator.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        sourceIndicator.isHidden = !compact || symbol == nil || !detailLabel.isHidden
        toolTip = "\(candidate.text) — \(candidate.label)"
        setAccessibilityLabel("\(number), \(candidate.text), \(candidate.label)")
        setAccessibilityValue(selected ? "Selected" : "")
        candidateLabel.textColor = .labelColor
        numberLabel.textColor = selected ? CandidateStyle.accent : .secondaryLabelColor
        detailLabel.textColor = .secondaryLabelColor
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        numberLabel.frame = NSRect(x: 10, y: (bounds.height - 14) / 2, width: 11, height: 14)
        if usesBadge, !detailLabel.isHidden {
            let badgeWidth = min(punctuationBadgeWidth, max(0, bounds.width - 25))
            let textWidth = max(0, min(candidateLabel.intrinsicContentSize.width + 4, bounds.width - 35 - badgeWidth))
            candidateLabel.frame = NSRect(x: 22, y: (bounds.height - 22) / 2, width: textWidth, height: 22)
            detailLabel.frame = NSRect(x: candidateLabel.frame.maxX + 3, y: (bounds.height - 14) / 2,
                                      width: badgeWidth, height: 14)
            sourceIndicator.frame = .zero
            return
        }
        let detailWidth = detailLabel.isHidden ? 0 : min(90, max(0, bounds.width - 90), detailLabel.intrinsicContentSize.width + 8)
        let indicatorWidth: CGFloat = sourceIndicator.isHidden ? 0 : 12
        let trailing: CGFloat = detailWidth > 0 ? detailWidth + 20 : indicatorWidth > 0 ? indicatorWidth + 14 : 10
        let textWidth = max(0, bounds.width - 22 - trailing)
        candidateLabel.frame = NSRect(x: 22, y: (bounds.height - 22) / 2, width: textWidth, height: 22)
        detailLabel.frame = NSRect(x: bounds.width - detailWidth - 10, y: (bounds.height - 14) / 2,
                                   width: detailWidth, height: 14)
        sourceIndicator.frame = NSRect(x: max(22, bounds.width - indicatorWidth - 9), y: (bounds.height - 12) / 2,
                                       width: indicatorWidth, height: 12)
    }

    var preferredWidth: CGFloat {
        if usesBadge, !detailLabel.isHidden {
            return 39 + candidateLabel.intrinsicContentSize.width + punctuationBadgeWidth
        }
        let detailWidth = detailLabel.isHidden ? 0 : min(90, detailLabel.intrinsicContentSize.width + 8) + 10
        let indicatorWidth: CGFloat = sourceIndicator.isHidden ? 0 : 16
        // Leave room for NSTextField's cell inset as well as glyph measurement.
        return 40 + candidateLabel.intrinsicContentSize.width + detailWidth + indicatorWidth
    }

    private var punctuationBadgeWidth: CGFloat { max(14, detailLabel.intrinsicContentSize.width + 5) }

    override func draw(_ dirtyRect: NSRect) {
        if isCurrent {
            CandidateStyle.selection.setFill()
            let radius: CGFloat = isCompact ? bounds.height / 2 : 8
            let highlight = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
            highlight.fill()
            if CandidateStyle.usesHighContrast {
                CandidateStyle.accent.setStroke()
                highlight.lineWidth = 1
                highlight.stroke()
            }
        }
        if usesBadge, !detailLabel.isHidden {
            let badge = NSBezierPath(roundedRect: detailLabel.frame, xRadius: 4, yRadius: 4)
            NSColor.labelColor.withAlphaComponent(CandidateStyle.usesHighContrast ? 0.15 : 0.07).setFill()
            badge.fill()
            if CandidateStyle.usesHighContrast {
                NSColor.secondaryLabelColor.setStroke()
                badge.lineWidth = 0.5
                badge.stroke()
            }
        }
    }

    // Labels must not take mouse events away from the row's button action.
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
}
