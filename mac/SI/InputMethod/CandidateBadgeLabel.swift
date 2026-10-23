import AppKit
import CoreText

/// NSTextField centers its line box; a tiny badge needs the visible letter centered instead.
@MainActor
final class CandidateBadgeLabel: NSTextField {
    var centersBadgeGlyph = false

    override func draw(_ dirtyRect: NSRect) {
        guard centersBadgeGlyph, let font, let textColor,
              let context = NSGraphicsContext.current?.cgContext else {
            super.draw(dirtyRect)
            return
        }
        let text = NSAttributedString(string: stringValue, attributes: [
            .font: font,
            .foregroundColor: textColor,
        ])
        let line = CTLineCreateWithAttributedString(text)
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        context.saveGState()
        if isFlipped {
            context.translateBy(x: 0, y: bounds.minY + bounds.maxY)
            context.scaleBy(x: 1, y: -1)
        }
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: bounds.midX - ink.midX, y: bounds.midY - ink.midY)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
