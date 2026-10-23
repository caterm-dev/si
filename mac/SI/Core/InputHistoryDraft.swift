import Foundation

/// Client-local and transient. Once edited outside composition, discard until the next boundary.
public struct InputHistoryDraft: Equatable, Sendable {
    public static let maximumBytes = 4_096
    public static let lifetime: TimeInterval = 5 * 60
    public private(set) var input = ""
    public private(set) var text = ""
    public private(set) var languages: Set<InputLanguage> = []
    public private(set) var isInvalid = false
    private var lastActivity: Date?

    public init() {}

    public mutating func invalidate() {
        self = InputHistoryDraft()
        isInvalid = true
    }

    public mutating func expire(now: Date = .now) {
        if let lastActivity, now < lastActivity || now.timeIntervalSince(lastActivity) >= Self.lifetime { invalidate() }
    }

    public mutating func append(input: String, text: String, languages: Set<InputLanguage> = [], now: Date = .now) {
        expire(now: now)
        guard !isInvalid else { return }
        guard !input.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              self.input.utf8.count + input.utf8.count <= Self.maximumBytes,
              self.text.utf8.count + text.utf8.count <= Self.maximumBytes else { invalidate(); return }
        self.input += input
        self.text += text
        self.languages.formUnion(languages)
        lastActivity = now
    }

    public mutating func append(_ commit: InputCommit, suffix: String = "", now: Date = .now) {
        // Explicit phrases and derived personal/verbatim paths stay outside automatic archives.
        guard commit.candidate?.isUserPhrase != true, commit.candidate?.hasLiteralSegments != true,
              commit.reason != .automaticConfirmation, commit.reason != .focusChange else { invalidate(); return }
        var languages: Set<InputLanguage> = []
        if let candidate = commit.candidate, let language = candidate.language {
            languages.insert(language)
            if candidate.isMixed { languages.insert(.english) }
        }
        append(input: (commit.candidate?.historyInput ?? commit.input) + suffix,
               text: commit.text + suffix, languages: languages, now: now)
    }

    public func entry(applicationID: String, now: Date = .now) -> ApplicationHistoryEntry? {
        guard !isInvalid, let lastActivity, now >= lastActivity,
              now.timeIntervalSince(lastActivity) < Self.lifetime,
              !input.trimmingCharacters(in: .whitespaces).isEmpty,
              !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return ApplicationHistoryEntry(applicationID: applicationID, input: input, text: text,
                                       languages: languages, count: 1, lastUsed: now)
    }
}
