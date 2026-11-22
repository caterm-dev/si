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
    static func frame(preferredSize: CGSize, anchor: CandidateAnchor) -> CGRect? {
        guard preferredSize.width.isFinite, preferredSize.height.isFinite,
              preferredSize.width > 0, preferredSize.height > 0 else { return nil }
        let available = anchor.screen.visibleFrame
        guard available.width > 0, available.height > 0 else { return nil }
        let size = CGSize(width: min(preferredSize.width, available.width), height: min(preferredSize.height, available.height))
        let x = min(max(anchor.rect.minX, available.minX), available.maxX - size.width)
        var y = anchor.rect.minY - size.height
        if y < available.minY { y = anchor.rect.maxY }
        y = min(max(y, available.minY), available.maxY - size.height)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }
}
