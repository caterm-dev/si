import Foundation
import CoreGraphics

enum CandidatePlacement {
    struct Screen {
        let frame: CGRect
        let visibleFrame: CGRect
    }

    static func normalizedAnchor(_ rect: CGRect) -> CGRect? {
        guard rect != .zero, !rect.isNull, !rect.isInfinite,
              rect.origin.x.isFinite, rect.origin.y.isFinite, rect.size.width.isFinite, rect.size.height.isFinite,
              rect.maxX.isFinite, rect.maxY.isFinite,
              rect.size.width >= 0, rect.size.height > 0 else { return nil }
        return CGRect(x: rect.minX, y: rect.minY, width: max(1, rect.width), height: rect.height)
    }

    static func screen(for anchor: CGRect, screens: [Screen]) -> Screen? {
        let start = CGPoint(x: anchor.minX, y: anchor.midY)
        let intersecting = screens.filter { !$0.frame.intersection(anchor).isEmpty }
        return intersecting.first { $0.frame.contains(start) } ?? intersecting.first
    }

    // InputMethodKit and AppKit already supply screen points; never apply a Retina scale here.
    static func availableWidth(at anchor: CandidateAnchor) -> CGFloat {
        // NSWindow rounds its size in screen points. Round down so the final
        // window cannot grow past a fractional remaining-width boundary.
        max(1, min(anchor.screen.visibleFrame.width,
                   anchor.screen.visibleFrame.maxX - anchor.rect.minX).rounded(.down))
    }

    static func frame(preferredSize: CGSize, anchor: CandidateAnchor) -> CGRect? {
        guard preferredSize.width.isFinite, preferredSize.height.isFinite,
              preferredSize.width > 0, preferredSize.height > 0 else { return nil }
        let available = anchor.screen.visibleFrame
        guard available.width > 0, available.height > 0 else { return nil }
        let size = CGSize(width: min(preferredSize.width, availableWidth(at: anchor)),
                          height: min(preferredSize.height, available.height))
        let below = anchor.rect.minY - size.height
        // Prefer below the line, but keep an expanded panel above it when the
        // bottom edge would be clipped by the display or Dock. If neither side
        // fits, keep the full frame within the display's visible vertical bounds.
        let preferredY = below >= available.minY ? below : anchor.rect.maxY
        let y = min(max(preferredY, available.minY), available.maxY - size.height)
        return CGRect(x: anchor.rect.minX, y: y, width: size.width, height: size.height)
    }
}
