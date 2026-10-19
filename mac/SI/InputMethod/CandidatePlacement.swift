import Foundation
import CoreGraphics

enum CandidatePlacement {
    struct Screen {
        let frame: CGRect
        let visibleFrame: CGRect
    }

    static func normalizedAnchor(_ rect: CGRect) -> CGRect? {
        guard !rect.isNull, !rect.isInfinite,
              rect.origin.x.isFinite, rect.origin.y.isFinite, rect.width.isFinite, rect.height.isFinite,
              rect.maxX.isFinite, rect.maxY.isFinite,
              rect.width >= 0, rect.height > 0 else { return nil }
        return CGRect(x: rect.minX, y: rect.minY, width: max(1, rect.width), height: rect.height)
    }

    static func screen(for anchor: CGRect, screens: [Screen]) -> Screen? {
        let center = CGPoint(x: anchor.midX, y: anchor.midY)
        return screens.first { $0.frame.contains(center) } ?? screens.first { $0.frame.intersects(anchor) }
    }

    // InputMethodKit and AppKit already supply screen points; never apply a Retina scale here.
    static func frame(preferredSize: CGSize, anchor: CGRect, screens: [Screen]) -> CGRect? {
        guard preferredSize.width.isFinite, preferredSize.height.isFinite,
              preferredSize.width > 0, preferredSize.height > 0,
              let anchor = normalizedAnchor(anchor), let screen = screen(for: anchor, screens: screens) else { return nil }
        let available = screen.visibleFrame.insetBy(dx: 4, dy: 4)
        guard available.width > 0, available.height > 0 else { return nil }
        let size = CGSize(width: min(preferredSize.width, available.width), height: min(preferredSize.height, available.height))
        let x = min(max(anchor.minX, available.minX), available.maxX - size.width)
        var y = anchor.minY - size.height - 4
        if y < available.minY { y = anchor.maxY + 4 }
        y = min(max(y, available.minY), available.maxY - size.height)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }
}
