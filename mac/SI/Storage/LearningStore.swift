import Foundation
#if SWIFT_PACKAGE
import SICore
#endif

/// File I/O is confined to this actor, never to the key-event handler or main actor.
public actor LearningStore {
    public enum StoreError: Error, Equatable {
        case unsupportedVersion
        case tooLarge
    }

    private struct Archive: Codable {
        let version: Int
        let entries: [LearnedPreference]
    }

    private let url: URL
    private var lastRevision = -1
    public static let maximumFileBytes = 16 * 1_024 * 1_024

    public init(url: URL) { self.url = url }

    public func load(now: Date = .now) throws -> LearningProfile {
        let data: Data
        do {
            guard let saved = try PrivateArchiveFile.read(url, maximumBytes: Self.maximumFileBytes) else { return LearningProfile() }
            data = saved
        } catch PrivateArchiveFile.FileError.tooLarge {
            throw StoreError.tooLarge
        }
        let archive = try JSONDecoder().decode(Archive.self, from: data)
        guard archive.version == 1 || archive.version == 2 else { throw StoreError.unsupportedVersion }
        let entries = archive.version == 1 ? archive.entries.map { entry in
            // The previous generator represented mixed candidates with a Chinese primary language.
            let mixed = entry.language == .simplifiedChinese && entry.text.unicodeScalars.contains {
                $0.isASCII && (($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122))
            }
            return LearnedPreference(input: entry.input, text: entry.text, language: entry.language,
                                     strength: entry.strength, lastUsed: entry.lastUsed, isMixed: mixed)
        } : archive.entries
        let profile = LearningProfile(entries: entries, now: now)
        // Physically remove expired/invalid entries on startup, even while learning is paused.
        if archive.version == 1 || profile.entries != archive.entries { try write(profile) }
        return profile
    }

    /// Revision guards prevent an older scheduled write from undoing a deletion or clear.
    public func save(_ profile: LearningProfile, revision: Int) throws {
        guard revision > lastRevision else { return }
        try write(profile)
        lastRevision = revision
    }

    public func erase(revision: Int) throws {
        guard revision > lastRevision else { return }
        try PrivateArchiveFile.erase(url)
        lastRevision = revision
    }

    private func write(_ profile: LearningProfile) throws {
        let data = try JSONEncoder().encode(Archive(version: 2, entries: profile.entries))
        do {
            try PrivateArchiveFile.write(data, to: url, maximumBytes: Self.maximumFileBytes)
        } catch PrivateArchiveFile.FileError.tooLarge {
            throw StoreError.tooLarge
        }
    }
}
