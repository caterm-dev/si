import Foundation

public enum CompositionBoundary {
    private static let supported = Set(".,;:!?()[]\"，。；：！？（）【】「」")
    private static let chinese: [String: String] = [
        ".": "。", ",": "，", ";": "；", ":": "：", "!": "！", "?": "？",
        "(": "（", ")": "）", "[": "【", "]": "】",
    ]

    public static func resolve(text: String, selected: InputCandidate?, explicitlySelected: Bool,
                               behavior: PunctuationBehavior) -> BoundaryResolution {
        guard behavior != .asTyped, text == "\t" || (text.count == 1 && text.first.map(supported.contains) == true),
              let selected, !selected.isLiteral, !selected.isPartial else { return BoundaryResolution() }
        let chineseEnding = prefersChinesePunctuation(selected)
        if !explicitlySelected {
            if selected.language == .english && !selected.isUserPhrase { return BoundaryResolution() }
            if selected.hasCompletion && (selected.isUserPhrase || !chineseEnding) { return BoundaryResolution() }
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
