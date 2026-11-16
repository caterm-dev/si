import Foundation

/// Validation shared by field capture and the learning store.
public enum SentenceSnapshot {
    public enum Coverage: Equatable, Sendable {
        case fullField
        case beforeCaret
    }

    public enum CaptureFailure: Error, Equatable, Sendable {
        case staleClient
        case markedText
        case incompleteRange
        case unavailableText
        case invalidText
    }

    public static func accepts(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            !CharacterSet.whitespacesAndNewlines.contains($0) && $0.properties.generalCategory != .control
        }
    }
}
