import AppKit

@MainActor
enum CandidateStyle {
    static let background = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.13, green: 0.135, blue: 0.15, alpha: 1)
            : NSColor(srgbRed: 1, green: 0.995, blue: 0.985, alpha: 1)
    }
    static let selection = NSColor.controlAccentColor
    static let selectionText = NSColor.alternateSelectedControlTextColor
    static let activeRow = selection.withAlphaComponent(0.04)
    static var usesHighContrast: Bool { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }
    static var outline: NSColor {
        usesHighContrast ? NSColor.labelColor.withAlphaComponent(0.6) : NSColor.separatorColor.withAlphaComponent(0.25)
    }
    static let stripHeight: CGFloat = 36
    static let rowHeight: CGFloat = 28
}
