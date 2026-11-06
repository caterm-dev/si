import Foundation
import SQLite3
import CryptoKit
import Darwin
#if SWIFT_PACKAGE
import SICore
#endif

/// All SQLite work is actor-isolated. History has no age/count eviction and is never loaded in full.
public actor InputHistoryStore {
    public enum StoreError: Error { case database, unsupportedVersion, invalidEntry, invalidExportDestination, exportRecordTooLarge }
    public enum Kind: Sendable {
        case submissions, sentences

        public var databasePath: String {
            switch self {
            case .submissions: "SI/InputHistory/history-v1.sqlite3"
            case .sentences: "SI/SentenceHistory/sentences-v1.sqlite3"
            }
        }
    }

    private let url: URL
    private let kind: Kind
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(url: URL, kind: Kind = .submissions) {
        self.url = url
        self.kind = kind
    }

    public func prepare() throws {
        try withDatabase { _ in () }
    }

    /// Stable event IDs make retry after an ambiguous write failure idempotent; repeated typing uses new IDs.
    public func append(_ entries: [InputHistoryEntry]) throws {
        guard entries.allSatisfy({ entry in
            entry.createdAt.timeIntervalSince1970.isFinite && validText(input: entry.input, output: entry.text)
        }) else {
            throw StoreError.invalidEntry
        }
        try withDatabase { database in
            try execute("BEGIN IMMEDIATE", database: database)
            do {
                for entry in entries {
                    try statement("INSERT INTO input_history (event_id, created_at, input, output, language, mixed, reason) VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(event_id) DO NOTHING", database: database) { query in
                        try bind(entry.id.uuidString, to: query, index: 1)
                        guard sqlite3_bind_double(query, 2, entry.createdAt.timeIntervalSince1970) == SQLITE_OK else { throw StoreError.database }
                        try bind(entry.input, to: query, index: 3)
                        try bind(entry.text, to: query, index: 4)
                        if let language = entry.language { try bind(language.rawValue, to: query, index: 5) }
                        else if sqlite3_bind_null(query, 5) != SQLITE_OK { throw StoreError.database }
                        guard sqlite3_bind_int(query, 6, entry.isMixed ? 1 : 0) == SQLITE_OK else { throw StoreError.database }
                        try bind(entry.reason.rawValue, to: query, index: 7)
                        guard sqlite3_step(query) == SQLITE_DONE else { throw StoreError.database }
                    }
                }
                try execute("COMMIT", database: database)
            } catch {
                try? execute("ROLLBACK", database: database)
                throw error
            }
        }
    }

    public func page(before cursor: Int64? = nil, search: String = "", limit: Int = 100) throws -> InputHistoryPage {
        let count = max(1, min(100, limit))
        return try withDatabase { database in
            try statement("SELECT sequence, event_id, created_at, input, output, language, mixed, reason FROM input_history WHERE sequence < ? AND (? = '' OR instr(lower(input), lower(?)) > 0 OR instr(lower(output), lower(?)) > 0) ORDER BY sequence DESC LIMIT ?", database: database) { query in
                guard sqlite3_bind_int64(query, 1, cursor ?? Int64.max) == SQLITE_OK,
                      sqlite3_bind_int(query, 5, Int32(count + 1)) == SQLITE_OK else { throw StoreError.database }
                for index: Int32 in 2...4 { try bind(search, to: query, index: index) }
                var entries: [InputHistoryEntry] = []
                var lastSequence: Int64?
                while true {
                    let result = sqlite3_step(query)
                    if result == SQLITE_DONE { return InputHistoryPage(entries: entries, nextCursor: nil) }
                    guard result == SQLITE_ROW else { throw StoreError.database }
                    if entries.count == count { return InputHistoryPage(entries: entries, nextCursor: lastSequence) }
                    guard let id = UUID(uuidString: text(query, column: 1)),
                          let reason = CommitReason(rawValue: text(query, column: 7)) else { throw StoreError.invalidEntry }
                    let rawLanguage = text(query, column: 5)
                    let language = InputLanguage(rawValue: rawLanguage)
                    guard rawLanguage.isEmpty || language != nil else { throw StoreError.invalidEntry }
                    entries.append(InputHistoryEntry(id: id, createdAt: Date(timeIntervalSince1970: sqlite3_column_double(query, 2)),
                        input: text(query, column: 3), text: text(query, column: 4), language: language,
                        isMixed: sqlite3_column_int(query, 6) != 0, reason: reason))
                    lastSequence = sqlite3_column_int64(query, 0)
                }
            }
        }
    }

    /// A complete, consistent JSONL snapshot. Text stays in one private temporary file until atomic publication.
    public func export(to destination: URL, now: Date = .now) throws -> Int {
        let target = destination.standardizedFileURL.resolvingSymlinksInPath()
        let sources = [url, URL.applicationSupportDirectory.appending(path: Kind.submissions.databasePath),
                       URL.applicationSupportDirectory.appending(path: Kind.sentences.databasePath)]
        guard target.pathExtension.lowercased() == "jsonl", !sources.contains(where: { source in
            ["", "-journal", "-wal", "-shm"].contains { suffix in
                URL(filePath: source.path + suffix).standardizedFileURL.resolvingSymlinksInPath() == target
            }
        }) else {
            throw StoreError.invalidExportDestination
        }
        let manager = FileManager.default
        let directory = destination.deletingLastPathComponent()
        let temporary = directory.appending(path: ".si-history-export-\(UUID().uuidString)")
        guard manager.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? manager.removeItem(at: temporary) }
        let file = try FileHandle(forWritingTo: temporary)
        defer { try? file.close() }
        var hash = SHA256()
        func write(_ object: [String: Any], hashed: Bool = true) throws {
            var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
            // The portable format bounds a single JSONL record, never the total history or record count.
            guard data.count <= 64 * 1_024 * 1_024 else { throw StoreError.exportRecordTooLarge }
            data.append(0x0a)
            try file.write(contentsOf: data)
            if hashed { hash.update(data: data) }
        }
        try write(["type": "manifest", "format": kind == .sentences ? "si-sentence-history" : "si-input-history",
                   "version": 1, "exported_at_unix": now.timeIntervalSince1970,
                   "scope": kind == .sentences ? "all_saved_sentences" : "all_saved_history"])
        let count = try withDatabase { database in
            try execute("BEGIN", database: database)
            defer { try? execute("ROLLBACK", database: database) }
            return try statement("SELECT sequence, event_id, created_at, input, output, language, mixed, reason FROM input_history ORDER BY sequence ASC", database: database) { query in
                var count = 0
                while true {
                    let result = sqlite3_step(query)
                    if result == SQLITE_DONE { return count }
                    guard result == SQLITE_ROW else { throw StoreError.database }
                    let rawID = text(query, column: 1)
                    let rawLanguage = text(query, column: 5)
                    let mixed = sqlite3_column_int(query, 6) != 0
                    guard UUID(uuidString: rawID)?.uuidString == rawID,
                          CommitReason(rawValue: text(query, column: 7)) != nil,
                          sqlite3_column_double(query, 2).isFinite,
                          validText(input: text(query, column: 3), output: text(query, column: 4)),
                          rawLanguage.isEmpty || InputLanguage(rawValue: rawLanguage) != nil,
                          !mixed || rawLanguage == InputLanguage.simplifiedChinese.rawValue else { throw StoreError.invalidEntry }
                    var object: [String: Any] = ["type": "entry", "sequence": sqlite3_column_int64(query, 0),
                        "id": text(query, column: 1), "created_at_unix": sqlite3_column_double(query, 2),
                        "output": text(query, column: 4)]
                    if kind == .submissions {
                        object["input"] = text(query, column: 3)
                        object["language"] = sqlite3_column_type(query, 5) == SQLITE_NULL ? NSNull() : text(query, column: 5) as Any
                        object["mixed"] = mixed
                        object["reason"] = text(query, column: 7)
                    }
                    try write(object)
                    count += 1
                }
            }
        }
        let digest = hash.finalize().map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined()
        try write(["type": "summary", "record_count": count, "sha256": digest], hashed: false)
        try file.synchronize()
        try file.close()
        // POSIX rename keeps the new file's 0600 permissions and atomically replaces only the chosen path.
        let published = temporary.withUnsafeFileSystemRepresentation { source in
            destination.withUnsafeFileSystemRepresentation { target in
                guard let source, let target else { return false }
                return Darwin.rename(source, target) == 0
            }
        }
        guard published else { throw CocoaError(.fileWriteUnknown) }
        return count
    }

    public func remove(id: UUID) throws {
        try withDatabase { database in
            try statement("DELETE FROM input_history WHERE event_id = ?", database: database) { query in
                try bind(id.uuidString, to: query, index: 1)
                guard sqlite3_step(query) == SQLITE_DONE else { throw StoreError.database }
            }
        }
    }

    /// Explicitly clears even a corrupt/unsupported database, without touching learning/phrases/legacy archives.
    public func clear() throws {
        for path in [url, URL(filePath: url.path + "-journal"), URL(filePath: url.path + "-wal"), URL(filePath: url.path + "-shm")] {
            try PrivateArchiveFile.erase(path)
        }
    }

    private func validText(input: String, output: String) -> Bool {
        switch kind {
        case .submissions: !input.isEmpty && !output.isEmpty
        case .sentences: input.isEmpty && SentenceSnapshot.accepts(output)
        }
    }

    private func withDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if manager.fileExists(atPath: url.path) {
            let attributes = try manager.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw StoreError.database }
        }
        var connection: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil)
        guard result == SQLITE_OK, let database = connection else {
            if let connection { sqlite3_close(connection) }
            throw StoreError.database
        }
        defer { sqlite3_close(database) }
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        sqlite3_busy_timeout(database, 1_000)
        let version = try statement("PRAGMA user_version", database: database) { query in
            guard sqlite3_step(query) == SQLITE_ROW else { throw StoreError.database }
            return sqlite3_column_int(query, 0)
        }
        guard version == 0 || version == 1 else { throw StoreError.unsupportedVersion }
        // Keep the two archive kinds distinguishable even if a file is copied to the other location.
        let expectedApplicationID: Int32 = kind == .sentences ? 0x53495348 : 0
        let applicationID = try statement("PRAGMA application_id", database: database) { query in
            guard sqlite3_step(query) == SQLITE_ROW else { throw StoreError.database }
            return sqlite3_column_int(query, 0)
        }
        guard applicationID == (version == 0 ? 0 : expectedApplicationID) else { throw StoreError.unsupportedVersion }
        let journalMode = try statement("PRAGMA journal_mode", database: database) { query in
            guard sqlite3_step(query) == SQLITE_ROW else { throw StoreError.database }
            return text(query, column: 0)
        }
        guard journalMode == "delete" else { throw StoreError.unsupportedVersion }
        try execute("PRAGMA trusted_schema = OFF", database: database)
        try execute("PRAGMA secure_delete = ON", database: database)
        if version == 0 {
            let existingTables = try statement("SELECT count(*) FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%'", database: database) { query in
                guard sqlite3_step(query) == SQLITE_ROW else { throw StoreError.database }
                return sqlite3_column_int(query, 0)
            }
            guard existingTables == 0 else { throw StoreError.unsupportedVersion }
            try execute("BEGIN IMMEDIATE", database: database)
            do {
                try execute("CREATE TABLE input_history (sequence INTEGER PRIMARY KEY AUTOINCREMENT, event_id TEXT NOT NULL UNIQUE, created_at REAL NOT NULL, input TEXT NOT NULL, output TEXT NOT NULL, language TEXT, mixed INTEGER NOT NULL, reason TEXT NOT NULL)", database: database)
                try execute("PRAGMA user_version = 1", database: database)
                if kind == .sentences { try execute("PRAGMA application_id = \(expectedApplicationID)", database: database) }
                try execute("COMMIT", database: database)
            } catch {
                try? execute("ROLLBACK", database: database)
                throw error
            }
        }
        try statement("SELECT sequence, event_id, created_at, input, output, language, mixed, reason FROM input_history LIMIT 0", database: database) { _ in () }
        return try body(database)
    }

    private func execute(_ sql: String, database: OpaquePointer) throws {
        // Never surface SQLite messages: they may embed submitted text.
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw StoreError.database }
    }

    private func statement<T>(_ sql: String, database: OpaquePointer, body: (OpaquePointer) throws -> T) throws -> T {
        var query: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &query, nil) == SQLITE_OK, let query else { throw StoreError.database }
        defer { sqlite3_finalize(query) }
        return try body(query)
    }

    private func bind(_ value: String, to query: OpaquePointer, index: Int32) throws {
        let result = value.utf8CString.withUnsafeBufferPointer {
            sqlite3_bind_text(query, index, $0.baseAddress, Int32($0.count - 1), transient)
        }
        guard result == SQLITE_OK else { throw StoreError.database }
    }

    private func text(_ query: OpaquePointer, column: Int32) -> String {
        guard let pointer = sqlite3_column_text(query, column) else { return "" }
        return String(decoding: UnsafeBufferPointer(start: pointer, count: Int(sqlite3_column_bytes(query, column))), as: UTF8.self)
    }
}
