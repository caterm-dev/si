import Foundation

/// Matches the Python training tokenizer: Unicode scalars plus lossless UTF-8 fallback.
public struct SmallRerankerTokenizer: Sendable {
    private let lookup: [Unicode.Scalar: Int32]

    public init(data: Data) throws {
        struct Archive: Decodable {
            let schema_version: Int
            let vocab_size: Int
            let characters: [String]
        }
        let archive = try JSONDecoder().decode(Archive.self, from: data)
        guard archive.schema_version == 1, archive.vocab_size == 16_384,
              archive.characters.count <= archive.vocab_size - 260 else { throw CocoaError(.fileReadCorruptFile) }
        var lookup: [Unicode.Scalar: Int32] = [:]
        for (index, text) in archive.characters.enumerated() {
            guard text.unicodeScalars.count == 1, let scalar = text.unicodeScalars.first,
                  lookup[scalar] == nil else { throw CocoaError(.fileReadCorruptFile) }
            lookup[scalar] = Int32(index + 260)
        }
        self.lookup = lookup
    }

    /// Excludes BOS/EOS. Refuses oversized text before allocating unbounded tensors.
    public func encode(_ text: String, limit: Int = 256) -> [Int32]? {
        guard !text.isEmpty, text.utf8.count <= 4_096 else { return nil }
        var result: [Int32] = []
        for scalar in text.unicodeScalars {
            guard !CharacterSet.controlCharacters.contains(scalar) else { return nil }
            if let token = lookup[scalar] { result.append(token) }
            else { result.append(contentsOf: String(scalar).utf8.map { Int32($0) + 4 }) }
            if result.count > limit { return nil }
        }
        return result
    }
}
