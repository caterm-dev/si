import Foundation

/// Bounds for one complete single-line text-client snapshot.
public enum SentenceSnapshot {
    public static let maximumUTF16Length = 1_024

    public static func accepts(_ text: String) -> Bool {
        !text.isEmpty && text.utf16.count <= maximumUTF16Length
            && !text.unicodeScalars.contains { CharacterSet.newlines.contains($0) || $0.properties.generalCategory == .control }
            && text.unicodeScalars.contains { !CharacterSet.whitespaces.contains($0) }
    }

    public static func range(endingAt selection: NSRange) -> NSRange? {
        guard (1...maximumUTF16Length).contains(selection.location), selection.length == 0 else { return nil }
        return NSRange(location: 0, length: selection.location)
    }
}
