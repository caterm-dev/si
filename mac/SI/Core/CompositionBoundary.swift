import Foundation

public enum CompositionBoundary {
    private static let symbolCharacters = CharacterSet.punctuationCharacters.union(.symbols)
    private static let supported = Set(",;:!?()[]\"，。；：！？（）【】「」")
    private static let chinese: [String: String] = [
        ",": "，", ";": "；", ":": "：", "!": "！", "?": "？",
        "(": "（", ")": "）", "[": "【", "]": "】",
    ]

    /// Symbols with no confirming policy can be inserted without resolving pending candidates.
    public static func keepsInComposition(text: String, behavior: PunctuationBehavior) -> Bool {
        isSymbol(text) && (behavior == .asTyped || text.count != 1 || text.first.map(supported.contains) != true)
    }

    private static func isSymbol(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: symbolCharacters.contains) && text.unicodeScalars.allSatisfy {
            symbolCharacters.contains($0) || CharacterSet.nonBaseCharacters.contains($0) || $0.value == 0x200D
        }
    }

    public static func resolve(text: String, selected: InputCandidate?, explicitlySelected: Bool,
                               behavior: PunctuationBehavior) -> BoundaryResolution {
        let literal = BoundaryResolution(continuesComposition: isSymbol(text))
        guard behavior != .asTyped, text == "\t" || (text.count == 1 && text.first.map(supported.contains) == true),
              let selected, !selected.isLiteral, !selected.isPartial else { return literal }
        let chineseEnding = prefersChinesePunctuation(selected)
        if !explicitlySelected {
            if selected.language == .english && !selected.isUserPhrase { return literal }
            if selected.hasCompletion && (selected.isUserPhrase || !chineseEnding) { return literal }
        }
        return BoundaryResolution(candidate: selected,
                                  replacement: behavior == .smart && chineseEnding ? chinese[text] : nil)
    }

    private static func prefersChinesePunctuation(_ candidate: InputCandidate) -> Bool {
        guard candidate.language == .simplifiedChinese else { return false }
        for scalar in candidate.text.unicodeScalars.reversed() {
            if CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) { return !scalar.isASCII }
        }
        return !candidate.isMixed
    }
}
