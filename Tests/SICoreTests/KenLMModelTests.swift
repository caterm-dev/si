import CryptoKit
import Foundation
import Testing
@testable import SICore

struct KenLMModelTests {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    @Test func trainingCleaningVectorsMatchByteForByte() throws {
        struct Vector: Decodable {
            let line: String
            let threshold: Int
            let expected: [String]?
        }
        struct Fixture: Decodable {
            let contract: String
            let counts: [String: Int]
            let dictionary: [String]
            let cases: [Vector]
        }
        let bytes = try Data(contentsOf: Self.root.appendingPathComponent("Tests/KenLMTests/cleaning_vectors.json"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: bytes)
        #expect(fixture.contract == KenLMCleaning.version)
        #expect(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() == KenLMCleaning.vectorsSHA)
        let counts = Dictionary(uniqueKeysWithValues: fixture.counts.map { (Data($0.key.utf8), $0.value) })
        let dictionary = Set(fixture.dictionary.map { Data($0.utf8) })
        for row in fixture.cases {
            let result = KenLMCleaning.line(row.line, count: { counts[$0, default: 0] },
                                            protected: { dictionary.contains($0) }, threshold: row.threshold)
            #expect(result?.map { Data($0.utf8) } == row.expected?.map { Data($0.utf8) })
        }
    }

    @Test func installedModelChecksManifestAndMatchesQuery() throws {
        guard let path = ProcessInfo.processInfo.environment["SI_TEST_KENLM_INSTALLATION"] else { return }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let model = try #require(KenLMModel.openInstalled(at: root))
        let number = try #require(model.wordIndex("１２.５"))
        let unknown = try #require(model.wordIndex("不在词表的测试词🪐"))
        #expect(number.index != 0 && !number.isOOV)
        #expect(unknown.index != 0 && unknown.isOOV)
        #expect(unknown.index == model.wordIndex("<oov>")?.index)
        #expect(model.wordIndex("<unk>") == nil)
        let initial = model.beginSentence()
        let step = try #require(model.advance(initial, wordIndex: number.index))
        let next = try #require(model.advance(step.state, wordIndex: unknown.index))
        #expect(abs(step.log10 - -1.1891373) < 0.000001)
        #expect(abs(next.log10 - -3.4547102) < 0.000001)
        let index = try Data(contentsOf: root.appendingPathComponent("current.json"))
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temp) }
        try index.write(to: temp.appendingPathComponent("current.json"))
        #expect(KenLMModel.openInstalled(at: temp) == nil)
    }
}
