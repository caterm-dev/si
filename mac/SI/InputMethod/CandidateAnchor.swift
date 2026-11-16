import CoreGraphics

// Recheck startup geometry after the host has had time to lay out a new field.
// Once startup ends, keep the anchor fixed for the rest of the composition.
struct CandidateAnchor {
    private var pinned: CGRect?
    private var pendingCorrection: CGRect?
    private var remainingRechecks = 4

    var needsRecheck: Bool { remainingRechecks > 0 }

    mutating func reset() {
        pinned = nil
        pendingCorrection = nil
        remainingRechecks = 4
    }

    mutating func resolve(screens: [CandidatePlacement.Screen], recheck: Bool = false,
                          trace: ((String, Int?, CGRect?) -> Void)? = nil,
                          queryStart: () -> CGRect) -> CGRect? {
        if let pinned, CandidatePlacement.screen(for: pinned, screens: screens) == nil { reset() }
        let shouldRecheck = recheck && needsRecheck
        if let pinned, !shouldRecheck {
            trace?("selected-pinned", nil, pinned)
            return pinned
        }
        if shouldRecheck { remainingRechecks -= 1 }
        let raw = queryStart()
        trace?(shouldRecheck ? "inline-recheck" : "inline", 0, raw)
        guard let rect = CandidatePlacement.normalizedAnchor(raw),
              rect.height < 200, rect.origin != .zero,
              CandidatePlacement.screen(for: rect, screens: screens) != nil else {
            pendingCorrection = nil
            trace?("unavailable", nil, nil)
            return pinned
        }
        if pinned == nil {
            pinned = rect
        } else if shouldRecheck {
            // One displaced response must not move a good anchor. Require the same
            // corrected start on two consecutive deferred host queries.
            if rect == pendingCorrection { pinned = rect }
            pendingCorrection = rect
        }
        trace?("selected-inline", 0, pinned)
        return pinned
    }
}
