import Foundation

/// One successful SI composition submission, separate from aggregate ranking preferences.
public struct InputHistoryEntry: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let input: String
    public let text: String
    public let language: InputLanguage?
    public let isMixed: Bool
    public let reason: CommitReason

    public init(id: UUID = UUID(), createdAt: Date = .now, input: String, text: String,
                language: InputLanguage?, isMixed: Bool = false, reason: CommitReason) {
        self.id = id
        self.createdAt = createdAt
        self.input = input
        self.text = text
        self.language = language
        self.isMixed = isMixed
        self.reason = reason
    }

    public init(commit: InputCommit, suffix: String = "", now: Date = .now) {
        self.init(createdAt: now, input: commit.input, text: commit.text + suffix,
                  language: commit.candidate?.language, isMixed: commit.candidate?.isMixed == true,
                  reason: commit.reason)
    }
}
