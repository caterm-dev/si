import Foundation
import SQLite3

struct DictionaryLexeme: Sendable {
    let text: String
    let reading: [String]
    let weight: Int64
    let ordinal: Int64
    // Raw fixture weights remain supported; production rows carry stored log10 probabilities.
    let logProbability: Double?
    var frequency: Double { logProbability ?? log10(Double(max(1, weight))) }

    init(text: String, reading: [String], weight: Int64, ordinal: Int64, logProbability: Double? = nil) {
        self.text = text
        self.reading = reading
        self.weight = weight
        self.ordinal = ordinal
        self.logProbability = logProbability
    }
    var key: String { reading.joined(separator: "'") }
}

/// A dictionary connection is immutable to SQLite. The lock owns every cached statement and
/// every SQLite call, including finalization. Sendability relies on this lock, not IMK callbacks.
final class LexiconDatabase: @unchecked Sendable {
    private let connection: OpaquePointer?
    private let lock = NSLock()
    private var statements: [String: OpaquePointer] = [:]
    let isAvailable: Bool
    let totalN: Int64
    let unknownLogProbability: Double?

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
           sqlite3_prepare_v2(connection, "SELECT key,value FROM meta", -1, &statement, nil) == SQLITE_OK,
           let statement {
            while sqlite3_step(statement) == SQLITE_ROW {
                if let key = sqlite3_column_text(statement, 0), let value = sqlite3_column_text(statement, 1) {
                    metadata[String(cString: key)] = String(cString: value)
                }
            }
        }
        if let statement { sqlite3_finalize(statement) }
        let total = Int64(metadata["total_n"] ?? "") ?? 0
        let unknown = Double(metadata["unk_logp"] ?? "")
        if metadata["schema_version"] != "2" || metadata["weight_unit"] != "si-log10-probability-v2"
            || metadata["log_base"] != "log10" || total <= 0
            || unknown.map({ !$0.isFinite || $0 >= 0 }) != false
            || (metadata["corpus_version"] ?? "").isEmpty
            || ISO8601DateFormatter().date(from: metadata["built_at"] ?? "") == nil {
            if let connection { sqlite3_close(connection) }
            connection = nil
        }
        self.connection = connection
        totalN = connection == nil ? 0 : total
        unknownLogProbability = connection == nil ? nil : unknown
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

    /// Missing dictionary words use the compiler-provided floor, without inventing a count.
    func logProbability(text: String, reading: [String]) -> Double? {
        guard let first = reading.first?.first(where: { "abcdefghijklmnopqrstuvwxyz".contains($0) }),
              !reading.isEmpty else { return unknownLogProbability }
        let bucket = reading.count <= 7 ? String(reading.count) : "others"
        return rows(table: "tbl_\(bucket)_\(first)", condition: "key=? AND value=?",
                    values: [reading.joined(separator: "'"), text], limit: 1).first?.logProbability
            ?? unknownLogProbability
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
                let logProbability = sqlite3_column_double(statement, 2)
                guard sqlite3_column_type(statement, 2) == SQLITE_FLOAT,
                      logProbability.isFinite, logProbability <= 0,
                      let unknownLogProbability, logProbability >= unknownLogProbability else { return [] }
                rows.append(DictionaryLexeme(text: value, reading: reading,
                                          weight: 0, ordinal: sqlite3_column_int64(statement, 3),
                                          logProbability: logProbability))
            }
            return status == SQLITE_DONE ? rows : []
        }
    }
}
