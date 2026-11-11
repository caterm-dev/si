import CoreGraphics

// Retain the first usable composition-start rectangle until this composition ends.
struct CandidateAnchor {
    private var pinned: CGRect?

    mutating func reset() {
        pinned = nil
    }

    mutating func resolve(screens: [CandidatePlacement.Screen],
                          trace: ((String, Int?, CGRect?) -> Void)? = nil,
                          queryStart: () -> CGRect) -> CGRect? {
        if let pinned, CandidatePlacement.screen(for: pinned, screens: screens) != nil {
            trace?("selected-pinned", nil, pinned)
            return pinned
        }
        reset()
        let raw = queryStart()
        trace?("inline", 0, raw)
        guard let rect = CandidatePlacement.normalizedAnchor(raw),
              rect.height < 200, rect.origin != .zero,
              CandidatePlacement.screen(for: rect, screens: screens) != nil else {
            trace?("unavailable", nil, nil)
            return nil
        }
        pinned = rect
        trace?("selected-inline", 0, rect)
        return rect
    }
}
