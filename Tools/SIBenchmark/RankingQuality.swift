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
        let engineRank: Int?
        let wholeRank: Int?
        let topFive: [String]
        let previewTopFive: [String]
        let wholeTopFive: [String]
        let bestWholeInputScore: Double?
        let bestPrefixInputScore: Double?
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
        let phonetic = URL(fileURLWithPath: "Data/Ranking/phonetic-regressions.json")
        let examples = try JSONDecoder().decode([Example].self, from: Data(contentsOf: path))
            + JSONDecoder().decode([Example].self, from: Data(contentsOf: holdout))
            + JSONDecoder().decode([Example].self, from: Data(contentsOf: phonetic))
        let engine = CandidateEngine()
        var results: [Result] = []
        for example in examples {
            let engineCandidates = engine.candidates(for: example.input, languages: Set(InputLanguage.allCases))
            let candidates = CandidateShortlist.candidates(from: engineCandidates)
            let whole = engineCandidates.filter { !$0.isPartial && !$0.isLiteral }
            let matches: (InputCandidate) -> Bool = { $0.text == example.expected && !$0.isPartial && !$0.isLiteral }
            var session = InputSession(engine: engine, candidateGeneration: .deferred)
            session.configure(languages: Set(InputLanguage.allCases))
            session.append(example.input)
            let preview = CandidateShortlist.candidates(from: session.pendingCandidateRequest!.generatePreview().candidates)
            results.append(Result(example: ExampleRecord(input: example.input, expected: example.expected, category: example.category),
                                  rank: candidates.firstIndex(where: matches).map { $0 + 1 },
                                  previewRank: preview.firstIndex(where: matches).map { $0 + 1 },
                                  engineRank: engineCandidates.firstIndex(where: matches).map { $0 + 1 },
                                  wholeRank: whole.firstIndex(where: matches).map { $0 + 1 },
                                  topFive: Array(candidates.prefix(5).map(\.text)),
                                  previewTopFive: Array(preview.prefix(5).map(\.text)),
                                  wholeTopFive: Array(whole.prefix(5).map(\.text)),
                                  bestWholeInputScore: whole.first?.inputScore,
                                  bestPrefixInputScore: engineCandidates.filter(\.isPartial).map(\.inputScore).max(),
                                  characterErrors: distance(candidates.first?.text ?? "", example.expected)))
        }
        let partitions = Dictionary(grouping: results) { $0.example.category.hasPrefix("holdout-") ? "historical-holdout"
            : ($0.example.category == "phonetic-regression" ? "phonetic-regressions" : "regression-and-development") }
            .mapValues { rows in Metrics(examples: rows.count, topOne: rows.count { $0.rank == 1 },
                                        topFive: rows.count { ($0.rank ?? .max) <= 5 }, recall: rows.count { $0.engineRank != nil },
                                        previewTopFive: rows.count { ($0.previewRank ?? .max) <= 5 }) }
        let report = Report(model: "SI shared-cost engine; actual ordered 27-choice window including prefixes", examples: results.count,
                            topOne: results.count { $0.rank == 1 }, topFive: results.count { ($0.rank ?? .max) <= 5 },
                            engineRecall: results.count { $0.engineRank != nil },
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
