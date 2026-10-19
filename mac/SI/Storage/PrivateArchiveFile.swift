import Foundation

/// Shared file mechanics. Callers confine this synchronous I/O to their storage actors.
enum PrivateArchiveFile {
    enum FileError: Error { case tooLarge }

    static func read(_ url: URL, maximumBytes: Int) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw CocoaError(.fileReadCorruptFile) }
        guard let size = attributes[.size] as? NSNumber, (0...maximumBytes).contains(size.intValue) else { throw FileError.tooLarge }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var data = Data()
        data.reserveCapacity(size.intValue)
        // Bound reads even if an externally selected import file grows after the size check.
        while true {
            let remaining = maximumBytes - data.count + 1
            guard let chunk = try file.read(upToCount: min(65_536, remaining)), !chunk.isEmpty else { break }
            data.append(chunk)
            guard data.count <= maximumBytes else { throw FileError.tooLarge }
        }
        return data
    }

    static func write(_ data: Data, to url: URL, maximumBytes: Int) throws {
        guard data.count <= maximumBytes else { throw FileError.tooLarge }
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        // The private directory protects atomic-write temporary files as well as the final file.
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try data.write(to: url, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func erase(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
