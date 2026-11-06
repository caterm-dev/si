import Foundation
#if SWIFT_PACKAGE
import SICore
#endif

/// Spaces decorate marked spelling only; editing and commits always use the session buffer.
struct MarkedTextPresentation {
    let text: String
    let cursorUTF16Offset: Int

    init(buffer: String, cursor: Int, candidates: [InputCandidate]) {
        let source = Array(buffer)
        // Prefix choices describe only consumed spelling. Use a complete hypothesis so
        // their unconverted remainder never acquires guessed syllable/word boundaries.
        let candidate = candidates.first { !$0.isLiteral && !$0.isPartial && !$0.hasLiteralSegments }
        let boundaries = Set(candidate?.sourceSegmentBoundaries ?? [])
        var display = ""
        var caret = 0
        for (offset, character) in source.enumerated() {
            if offset > 0, boundaries.contains(offset), source[offset - 1] != "'", character != "'",
               !source[offset - 1].isWhitespace, !character.isWhitespace {
                display.append(" ")
            }
            if offset == cursor { caret = display.utf16.count }
            display.append(character)
        }
        text = display
        cursorUTF16Offset = cursor >= source.count ? display.utf16.count : caret
    }
}
