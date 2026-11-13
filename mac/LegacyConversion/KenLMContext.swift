import Foundation
import NaturalLanguage

/// A bounded, transient host prefix. Tokenization runs only on the candidate worker.
public struct KenLMContext: Sendable, Equatable {
    public static let maximumUTF16Length = 256
    public static let empty = KenLMContext(text: "")
    private let text: String
    private let isTruncated: Bool

    public init(text: String, isTruncated: Bool = false) {
        // Reject oversized/incomplete snapshots rather than inventing a source boundary.
        self.text = text.utf16.count <= Self.maximumUTF16Length ? text : ""
        self.isTruncated = isTruncated
    }

    var tokens: [String] {
        // Match the training Han range. Other languages, punctuation and newlines
        // end a segment; horizontal whitespace may separate Chinese words.
        let scalars = text.precomposedStringWithCompatibilityMapping.unicodeScalars
        let boundary = scalars.lastIndex { !(0x4e00...0x9fff).contains($0.value) && $0 != " " && $0 != "\t" }
        let start = boundary.map { scalars.index(after: $0) } ?? scalars.startIndex
        let tail = scalars[start...]
        let source = String(tail)
        guard !source.isEmpty else { return [] }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.setLanguage(.simplifiedChinese)
        tokenizer.string = source
        var words: [String] = []
        tokenizer.enumerateTokens(in: source.startIndex..<source.endIndex) { range, _ in
            words.append(String(source[range]))
            return true
        }
        // At the read limit the first word may be cut in half. Never use it.
        if isTruncated && tail.count == scalars.count && !words.isEmpty { words.removeFirst() }
        return Array(words.suffix(3))
    }
}
