import Foundation

enum CandidateGeometryReader {
    /// Prefer geometry tied to a verified document position. Some clients return
    /// an on-screen placeholder from the inline API instead of the insertion point.
    /// Nil means the request became obsolete; an unusable rectangle remains a fallback.
    static func read(inlineOffset: Int, documentBounds: NSRange?, screens: [CandidatePlacement.Screen],
                     isCurrent: () -> Bool,
                     documentRectangle: (NSRange) -> (rect: CGRect, actual: NSRange)?,
                     inlineRectangle: (Int) -> CGRect) -> CGRect? {
        guard isCurrent() else { return nil }
        if let bounds = documentBounds,
           let requested = CandidateAnchor.documentRange(inlineOffset: inlineOffset,
                                                         inlineUTF16Count: bounds.length, marked: bounds) {
            let response = documentRectangle(requested)
            guard isCurrent() else { return nil }
            if let response,
               CandidateAnchor.acceptsDocumentGeometry(actual: response.actual, requested: requested, marked: bounds),
               CandidateAnchor(response.rect, screens: screens) != nil {
                return response.rect
            }
        }
        let rect = inlineRectangle(inlineOffset)
        guard isCurrent() else { return nil }
        return rect
    }
}
