import Foundation
import SQLite3
import Testing
@testable import SICore

struct DictionaryDatabaseTests {
    private func schema(at url: URL) throws -> [String] {
        var connection: OpaquePointer?
        #expect(sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        defer { sqlite3_close(connection) }
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(connection,
            "SELECT sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY name", -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        var result: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let text = try #require(sqlite3_column_text(statement, 0))
            result.append(String(cString: text))
        }
        return result
    }

    @Test func bothBundledLanguagesUseIdenticalSchemaAndWeightUnits() throws {
        let chineseURL = try #require(ChineseResources.url("si-pinyin", extension: "sqlite"))
        let englishURL = try #require(DictionaryResources.url("si-english", extension: "sqlite", languageDirectory: "English"))
        #expect(try schema(at: chineseURL) == schema(at: englishURL))
        let chinese = LexiconDatabase(url: chineseURL), english = LexiconDatabase(url: englishURL)
        #expect(chinese.isAvailable && english.isAvailable)
        #expect(chinese.referenceMass == english.referenceMass)
        #expect(chinese.referenceMass == 7_694_577_936)
        #expect(english.allEntries().count == 63_602)
        #expect(english.rows(table: "tbl_1_g", condition: "key=?", values: ["gmail"], limit: nil).first?.text == "Gmail")
        #expect(!chinese.rows(table: "tbl_1_s", condition: "key=?", values: ["shi"], limit: nil).isEmpty)
    }

    @Test(arguments: ["unrecognized", "si-relative-frequency-v1"])
    func missingOrIncompatibleResourcesNeverCreateOrRepairFiles(unit: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("synthetic.sqlite")
        #expect(!LexiconDatabase(url: url).isAvailable)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        var connection: OpaquePointer?
        #expect(sqlite3_open(url.path, &connection) == SQLITE_OK)
        #expect(sqlite3_exec(connection, "CREATE TABLE dictionary_metadata (key TEXT, value TEXT); "
            + "INSERT INTO dictionary_metadata VALUES ('schema_version','1'),('weight_unit','\(unit)'),"
            + "('reference_mass','1000'),('unknown_weight','1')", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(connection)
        let before = try Data(contentsOf: url)
        let database = LexiconDatabase(url: url)
        #expect(!database.isAvailable)
        #expect(database.allEntries().isEmpty)
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func sharedStatementCacheKeepsConcurrentLookupsDeterministic() async throws {
        let url = try #require(DictionaryResources.url("si-english", extension: "sqlite", languageDirectory: "English"))
        let database = LexiconDatabase(url: url)
        let expected = database.rows(table: "tbl_1_a", condition: "key>=? AND key<?", values: ["ab", "ac"], limit: nil)
        #expect(!expected.isEmpty)
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    let rows = database.rows(table: "tbl_1_a", condition: "key>=? AND key<?", values: ["ab", "ac"], limit: nil)
                    return rows.map(\.text) == expected.map(\.text) && rows.map(\.weight) == expected.map(\.weight)
                }
            }
            for await matches in group { #expect(matches) }
        }
    }
}
