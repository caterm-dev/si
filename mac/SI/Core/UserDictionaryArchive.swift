import Foundation

public enum UserDictionaryArchive {
    public static let maximumBytes = 4 * 1_024 * 1_024
    public enum ArchiveError: Error, Equatable {
        case tooLarge
        case unsupportedFormat
    }

    private struct Document: Codable {
        let format: String
        let version: Int
        let entries: [UserPhrase]
    }

    public static func decode(_ data: Data) throws -> UserDictionary {
        guard data.count <= maximumBytes else { throw ArchiveError.tooLarge }
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.version == 1, document.format == "SI User Dictionary" else { throw ArchiveError.unsupportedFormat }
        // Codable decoding does not run UserPhrase's validating initializer.
        return try UserDictionary(entries: document.entries)
    }

    public static func encode(_ dictionary: UserDictionary) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Document(format: "SI User Dictionary", version: 1, entries: dictionary.entries))
        guard data.count <= maximumBytes else { throw ArchiveError.tooLarge }
        return data
    }
}
