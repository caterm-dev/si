import Foundation
#if SWIFT_PACKAGE
import SICore
#endif

public actor UserDictionaryStore {
    private let url: URL
    private var lastRevision = -1

    public init(url: URL) { self.url = url }

    public func load() throws -> UserDictionary {
        guard let data = try PrivateArchiveFile.read(url, maximumBytes: UserDictionaryArchive.maximumBytes) else {
            return UserDictionary()
        }
        return try UserDictionaryArchive.decode(data)
    }

    public func save(_ dictionary: UserDictionary, revision: Int) throws {
        guard revision > lastRevision else { return }
        let data = try UserDictionaryArchive.encode(dictionary)
        try PrivateArchiveFile.write(data, to: url, maximumBytes: UserDictionaryArchive.maximumBytes)
        lastRevision = revision
    }

    public func erase(revision: Int) throws {
        guard revision > lastRevision else { return }
        try PrivateArchiveFile.erase(url)
        lastRevision = revision
    }

    public func readImport(at url: URL) throws -> UserDictionary {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
        guard let data = try PrivateArchiveFile.read(url, maximumBytes: UserDictionaryArchive.maximumBytes) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try UserDictionaryArchive.decode(data)
    }

    public func export(_ dictionary: UserDictionary) throws -> Data {
        try UserDictionaryArchive.encode(dictionary)
    }
}
