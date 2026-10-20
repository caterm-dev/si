import AppKit

@MainActor
enum CandidateStyle {
    static let background = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.13, green: 0.135, blue: 0.15, alpha: 1)
            : NSColor(srgbRed: 1, green: 0.995, blue: 0.985, alpha: 1)
    }
    static let selection = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.28, green: 0.205, blue: 0.18, alpha: 1)
            : NSColor(srgbRed: 1, green: 0.935, blue: 0.90, alpha: 1)
    }
    static let accent = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 1, green: 0.65, blue: 0.46, alpha: 1)
            : NSColor(srgbRed: 0.78, green: 0.245, blue: 0.08, alpha: 1)
    }
    static var usesHighContrast: Bool { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }
    static var outline: NSColor {
        usesHighContrast ? NSColor.labelColor.withAlphaComponent(0.6) : NSColor.separatorColor.withAlphaComponent(0.25)
    }
    static let stripHeight: CGFloat = 36
    static let rowHeight: CGFloat = 28
}
