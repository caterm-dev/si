import Foundation
import SICore

/// Explicit synthetic fixtures only. This tool never reads the learning archive or host text.
enum RankingQuality {
    struct Example: Decodable {
        let input: String
        let expected: String
        let category: String
    }
    struct Result: Encodable {
        let example: ExampleRecord
        let rank: Int?
        let previewRank: Int?
        let topFive: [String]
        let previewTopFive: [String]
        let characterErrors: Int
    }
    struct ExampleRecord: Encodable {
        let input: String
        let expected: String
        let category: String
    }
    struct Report: Encodable {
        let model: String
        let examples: Int
        let topOne: Int
        let topFive: Int
        let engineRecall: Int
        let previewTopFive: Int
        let stageFirstChoiceAgreement: Int
        let characterErrorRate: Double
        let partitions: [String: Metrics]
        let results: [Result]
    }
    struct Metrics: Encodable {
        let examples: Int
        let topOne: Int
        let topFive: Int
        let recall: Int
        let previewTopFive: Int
    }

    static func run() throws {
        let path = URL(fileURLWithPath: "Data/Ranking/evaluation.json")
        let holdout = URL(fileURLWithPath: "Data/Ranking/holdout.json")
        let examples = try JSONDecoder().decode([Example].self, from: Data(contentsOf: path))
            + JSONDecoder().decode([Example].self, from: Data(contentsOf: holdout))
        let engine = CandidateEngine()
        var results: [Result] = []
        for example in examples {
            let candidates = engine.candidates(for: example.input, languages: Set(InputLanguage.allCases))
                .filter { !$0.isPartial && !$0.isLiteral }
            var session = InputSession(engine: engine, candidateGeneration: .deferred)
            session.configure(languages: Set(InputLanguage.allCases))
            session.append(example.input)
            let preview = session.pendingCandidateRequest!.generatePreview().candidates.filter { !$0.isPartial && !$0.isLiteral }
            results.append(Result(example: ExampleRecord(input: example.input, expected: example.expected, category: example.category),
                                  rank: candidates.firstIndex { $0.text == example.expected }.map { $0 + 1 },
                                  previewRank: preview.firstIndex { $0.text == example.expected }.map { $0 + 1 },
                                  topFive: Array(candidates.prefix(5).map(\.text)),
                                  previewTopFive: Array(preview.prefix(5).map(\.text)),
                                  characterErrors: distance(candidates.first?.text ?? "", example.expected)))
        }
        let partitions = Dictionary(grouping: results) { $0.example.category.hasPrefix("holdout-") ? "holdout" : "regression-and-development" }
            .mapValues { rows in Metrics(examples: rows.count, topOne: rows.count { $0.rank == 1 },
                                        topFive: rows.count { ($0.rank ?? .max) <= 5 }, recall: rows.count { $0.rank != nil },
                                        previewTopFive: rows.count { ($0.previewRank ?? .max) <= 5 }) }
        let report = Report(model: "SI unified lexical Witten-Bell + wordfreq 3.1.1", examples: results.count,
                            topOne: results.count { $0.rank == 1 }, topFive: results.count { ($0.rank ?? .max) <= 5 },
                            engineRecall: results.count { $0.rank != nil },
                            previewTopFive: results.count { ($0.previewRank ?? .max) <= 5 },
                            stageFirstChoiceAgreement: results.count { $0.topFive.first == $0.previewTopFive.first },
                            characterErrorRate: Double(results.reduce(0) { $0 + $1.characterErrors })
                                / Double(max(1, examples.reduce(0) { $0 + $1.expected.count })), partitions: partitions, results: results)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: try encoder.encode(report), as: UTF8.self))
    }

    private static func distance(_ left: String, _ right: String) -> Int {
        let lhs = Array(left), rhs = Array(right)
        var row = Array(0...rhs.count)
        for (i, a) in lhs.enumerated() {
            var next = [i + 1]
            for (j, b) in rhs.enumerated() { next.append(min(row[j + 1] + 1, next[j] + 1, row[j] + (a == b ? 0 : 1))) }
            row = next
        }
        return row[rhs.count]
    }
}
