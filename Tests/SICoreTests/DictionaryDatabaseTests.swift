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
        #expect(chinese.totalN > 0 && english.totalN > 0)
        #expect(chinese.unknownLogProbability?.isFinite == true)
        #expect(english.unknownLogProbability?.isFinite == true)
        #expect(english.allEntries().count >= 72_784)
        #expect(english.logProbability(text: "not-a-dictionary-word", reading: ["notadictionaryword"])
                == english.unknownLogProbability)
        #expect(english.logProbability(text: "163.com", reading: ["163.com"]) != english.unknownLogProbability)
        #expect(english.rows(table: "tbl_1_g", condition: "key=?", values: ["gmail"], limit: nil).first?.text == "gmail")
        #expect(!chinese.rows(table: "tbl_1_s", condition: "key=?", values: ["shi"], limit: nil).isEmpty)
    }

    @Test func storedLogProbabilitiesAndUnknownFloorAreUsedWithoutIntegerTruncation() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        var connection: OpaquePointer?
        #expect(sqlite3_open(url.path, &connection) == SQLITE_OK)
        let floor = log10(0.5 / 100)
        let sql = "CREATE TABLE meta (key TEXT PRIMARY KEY,value TEXT NOT NULL); "
            + "INSERT INTO meta VALUES ('schema_version','2'),('weight_unit','si-log10-probability-v2'),"
            + "('total_n','100'),('log_base','log10'),('corpus_version','synthetic-v1'),"
            + "('built_at','2026-11-10T00:00:00+00:00'),('unk_logp','\(floor)'); "
            + "CREATE TABLE tbl_1_n (key TEXT,jp TEXT,value TEXT,weight REAL NOT NULL); "
            + "INSERT INTO tbl_1_n VALUES ('ne','n','呢',\(log10(0.2)));"
        #expect(sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(connection)
        let database = LexiconDatabase(url: url)
        #expect(database.isAvailable)
        #expect(database.logProbability(text: "呢", reading: ["ne"]) == log10(0.2))
        #expect(database.logProbability(text: "讷", reading: ["ne"]) == floor)
        let row = try #require(database.rows(table: "tbl_1_n", condition: "key=?", values: ["ne"], limit: 1).first)
        #expect(row.logProbability == log10(0.2))
        #expect(abs(CandidateScoring.wordCost(row) - (-1.05 * log2(0.2))) < 1e-12)
        let englishURL = try #require(DictionaryResources.url("si-english", extension: "sqlite", languageDirectory: "English"))
        let english = LexiconDatabase(url: englishURL)
        let unknown = try #require(english.unknownLogProbability)
        #expect(abs(EnglishLexicon.unknownProbability - pow(10.0, unknown)) < 1e-15)
        #expect(EnglishLexicon.unknownCost == CandidateScoring.wordCost(logProbability: unknown))
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
        let mass = unit == "si-relative-frequency-v1" ? "7694577936" : "1"
        #expect(sqlite3_exec(connection, "CREATE TABLE dictionary_metadata (key TEXT, value TEXT); "
            + "INSERT INTO dictionary_metadata VALUES ('schema_version','1'),('weight_unit','\(unit)'),"
            + "('reference_mass','\(mass)'),('unknown_weight','1')", nil, nil, nil) == SQLITE_OK)
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
                    return rows.map(\.text) == expected.map(\.text) && rows.map(\.logProbability) == expected.map(\.logProbability)
                }
            }
            for await matches in group { #expect(matches) }
        }
    }
}
