import AppKit
import CoreText

/// Font coverage belongs to presentation, not the shared dictionary or ranking engine.
struct CandidateTextSupport {
    static var font: NSFont { .systemFont(ofSize: 15) }
    private var coverage: [[UInt8]: Bool] = [:]
    private static let cacheLimit = 1_024

    mutating func canDisplay(_ text: String) -> Bool {
        // Shape whole graphemes so surrogate pairs, combining marks and emoji
        // sequences use the same system fallback as the candidate label.
        for character in text {
            let cluster = String(character)
            let key = Array(cluster.utf8)
            if let supported = coverage[key] {
                if !supported { return false }
                continue
            }
            let supported = Self.hasGlyphs(cluster)
            if coverage.count >= Self.cacheLimit { coverage.removeAll(keepingCapacity: true) }
            coverage[key] = supported
            if !supported { return false }
        }
        return true
    }

    private static func hasGlyphs(_ text: String) -> Bool {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let font = attributes[kCTFontAttributeName] else { return false }
            let runFont = font as! CTFont
            // LastResort has nonzero glyph IDs, but draws missing-character boxes.
            if CTFontCopyPostScriptName(runFont) as String == "LastResort" { return false }
            var glyphs = [CGGlyph](repeating: 0, count: CTRunGetGlyphCount(run))
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            if glyphs.contains(0) { return false }
        }
        return true
    }
}
