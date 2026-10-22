import Foundation
import SQLite3

struct DictionaryLexeme: Sendable {
    let text: String
    let reading: [String]
    let weight: Int64
    let ordinal: Int64
    var key: String { reading.joined(separator: "'") }
}

/// A dictionary connection is immutable to SQLite. The lock owns every cached statement and
/// every SQLite call, including finalization. Sendability relies on this lock, not IMK callbacks.
final class LexiconDatabase: @unchecked Sendable {
    // Versioned wire contract in Data/DictionaryFormat.json. A changed reference
    // mass requires a new unit/version rather than silently mixing scales.
    private static let weightReferenceMass: Int64 = 7_694_577_936
    private let connection: OpaquePointer?
    private let lock = NSLock()
    private var statements: [String: OpaquePointer] = [:]
    let isAvailable: Bool
    let referenceMass: Int64
    let unknownWeight: Int64

    init(url: URL?) {
        var connection: OpaquePointer?
        if let url {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "mode", value: "ro"), URLQueryItem(name: "immutable", value: "1")]
            if let address = components?.string,
               sqlite3_open_v2(address, &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil) != SQLITE_OK {
                if let connection { sqlite3_close(connection) }
                connection = nil
            }
        }
        // Both languages require the same versioned weight contract. A missing or
        // incompatible resource fails closed; never create or repair a database at runtime.
        var metadata: [String: String] = [:]
        var statement: OpaquePointer?
        if let connection,
           sqlite3_prepare_v2(connection, "SELECT key,value FROM dictionary_metadata", -1, &statement, nil) == SQLITE_OK,
           let statement {
            while sqlite3_step(statement) == SQLITE_ROW {
                if let key = sqlite3_column_text(statement, 0), let value = sqlite3_column_text(statement, 1) {
                    metadata[String(cString: key)] = String(cString: value)
                }
            }
        }
        if let statement { sqlite3_finalize(statement) }
        let mass = Int64(metadata["reference_mass"] ?? "") ?? 0
        let unknown = Int64(metadata["unknown_weight"] ?? "") ?? 0
        if metadata["schema_version"] != "1" || metadata["weight_unit"] != "si-relative-frequency-v1"
            || mass != Self.weightReferenceMass || unknown <= 0 {
            if let connection { sqlite3_close(connection) }
            connection = nil
        }
        self.connection = connection
        referenceMass = mass
        unknownWeight = unknown
        isAvailable = connection != nil
    }

    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        if let connection { sqlite3_close(connection) }
    }

    func rows(table: String, condition: String, values: [String], limit: Int?) -> [DictionaryLexeme] {
        // Table names are made solely from the fixed syllable bucket and ASCII initial below.
        let sql = "SELECT key,value,weight,rowid FROM \(table) WHERE \(condition) ORDER BY weight DESC,rowid ASC"
            + (limit.map { " LIMIT \(max(0, $0))" } ?? "")
        return read(sql: sql, values: values)
    }

    /// Loaded once on a candidate worker to construct the immutable English trie.
    /// A single compound query fails as a whole if any required table is unavailable.
    func allEntries() -> [DictionaryLexeme] {
        let tables = (1...8).flatMap { bucket in
            "abcdefghijklmnopqrstuvwxyz".map { "tbl_\(bucket == 8 ? "others" : String(bucket))_\($0)" }
        }
        let sql = tables.map { "SELECT key,value,weight,rowid FROM \($0)" }.joined(separator: " UNION ALL ")
            + " ORDER BY key COLLATE BINARY ASC,4 ASC"
        return read(sql: sql, values: [])
    }

    private func read(sql: String, values: [String]) -> [DictionaryLexeme] {
        guard let connection else { return [] }
        return lock.withLock {
            let statement: OpaquePointer
            if let cached = statements[sql] { statement = cached }
            else {
                var prepared: OpaquePointer?
                guard sqlite3_prepare_v2(connection, sql, -1, &prepared, nil) == SQLITE_OK, let prepared else {
                    if let prepared { sqlite3_finalize(prepared) }
                    return []
                }
                if statements.count >= 512 {
                    for old in statements.values { sqlite3_finalize(old) }
                    statements.removeAll(keepingCapacity: true)
                }
                statements[sql] = prepared
                statement = prepared
            }
            defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
            for (index, value) in values.enumerated() {
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                let bound = value.withCString { sqlite3_bind_text(statement, Int32(index + 1), $0, -1, transient) }
                guard bound == SQLITE_OK else { return [] }
            }
            var rows: [DictionaryLexeme] = []
            var status = sqlite3_step(statement)
            while status == SQLITE_ROW {
                defer { status = sqlite3_step(statement) }
                guard let key = sqlite3_column_text(statement, 0), let text = sqlite3_column_text(statement, 1) else { continue }
                let reading = String(cString: key).split(separator: "'").map(String.init)
                let value = String(cString: text)
                guard !value.isEmpty, value.utf8.count <= PinyinDecoder.maximumOutputBytes else { continue }
                rows.append(DictionaryLexeme(text: value, reading: reading,
                                          weight: sqlite3_column_int64(statement, 2), ordinal: sqlite3_column_int64(statement, 3)))
            }
            return status == SQLITE_DONE ? rows : []
        }
    }
}
