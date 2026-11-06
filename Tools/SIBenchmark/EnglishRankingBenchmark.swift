import CryptoKit
import Foundation
import SICore

enum EnglishRankingBenchmark {
    private typealias Query = KenLMRankingBenchmark.Query
    private typealias Benchmark = KenLMRankingBenchmark
    private static let both: Set<InputLanguage> = [.english, .simplifiedChinese]
    private static let legacy = RankingExperiment.defaultEnglishWordInsertionBits
    private static let penalties: [Double] = [24, 28, 30, 32, legacy, 34, 35, 36, 37, 38, 40, 42, 46, 50]

    private struct Winner: Encodable {
        let text: String
        let outcome: String

        init(_ top: InputCandidate?, query: Query) {
            text = top?.text ?? ""
            if let top, Benchmark.Metrics.correct(top, query.expected) && top.language == .english && !top.isMixed {
                outcome = "whole"
            } else if let top, top.language == .english, !top.isMixed, !top.isPartial {
                let words = text.lowercased().split(separator: " ")
                outcome = words.count > 1 && words.joined() == query.input ? "split" : "otherEnglish"
            } else {
                outcome = top?.isLiteral == true ? "literal" : "other"
            }
        }
    }

    private struct AuditRow: Encodable {
        let input: String
        let expected: String
        let english: Winner
        let bilingual: Winner
    }

    private struct Counts: Encodable {
        var queries = 0
        var top1 = 0
        var top5 = 0

        mutating func record(_ candidates: ArraySlice<InputCandidate>, expected: String) {
            func correct(_ candidate: InputCandidate) -> Bool {
                candidate.language == .english && !candidate.isMixed && Benchmark.Metrics.correct(candidate, expected)
            }
            queries += 1
            top1 += candidates.first.map(correct) == true ? 1 : 0
            top5 += candidates.contains(where: correct) ? 1 : 0
        }
    }

    private struct GridRow: Encodable {
        let penalty: Double
        var metrics: [String: Counts] = [:]

        var macroTop1: Double {
            metrics.keys.sorted().reduce(0) { total, key in
                let counts = metrics[key]!
                return total + Double(counts.top1) / Double(counts.queries)
            } / Double(metrics.count)
        }

        mutating func record(_ candidates: [InputCandidate], for query: Query, group: String) {
            let top = CandidateShortlist.candidates(from: candidates).prefix(5)
            metrics[group, default: Counts()].record(top, expected: query.expected)
        }
    }

    private struct GridReport: Encodable {
        let selectedPenalty: Double
        let coLeaders: [Double]
        let grid: [GridRow]
        let validation: [GridRow]
        let originalRegression: [GridRow]
    }

    static func run(_ arguments: [String]) throws {
        if arguments.count == 2 && arguments[0] == "audit" {
            try Benchmark.encode(audit(Benchmark.read(URL(fileURLWithPath: arguments[1]))))
        } else if arguments.count == 3 && arguments[0] == "grid" {
            let original = try Benchmark.read(URL(fileURLWithPath: arguments[1]))
            let guards = try Benchmark.read(URL(fileURLWithPath: arguments[2]))
            try Benchmark.encode(grid(original: original, guards: guards))
        } else {
            throw NSError(domain: "EnglishRankingBenchmark", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Use --english-ranking audit AUDIT_JSONL or grid ENGLISH_JSONL GUARD_JSONL."
            ])
        }
    }

    private static func audit(_ queries: [Query]) -> [AuditRow] {
        let engine = CandidateEngine(rankingExperiment: RankingExperiment(fullCoverageFirst: true))
        return queries.enumerated().map { index, query in
            func winner(_ languages: Set<InputLanguage>) -> Winner {
                let candidates = engine.candidates(for: query.input, languages: languages, now: Benchmark.fixedDate)
                return Winner(CandidateShortlist.candidates(from: candidates).first, query: query)
            }
            let english = winner([.english]), bilingual = winner(both)
            if index % 2_000 == 0 { Benchmark.progress("audit \(index)/\(queries.count)") }
            return AuditRow(input: query.input, expected: query.expected, english: english, bilingual: bilingual)
        }
    }

    private static func grid(original: [Query], guards: [Query]) -> GridReport {
        // Use the same stable word-family split for both sources, including overlaps.
        func isDevelopment(_ query: Query) -> Bool {
            let key = query.id.split(separator: "/")[0].dropFirst(3)
            return SHA256.hash(data: Data(key.utf8)).withUnsafeBytes { $0[0] < 154 }
        }
        let development = (original + guards).filter(isDevelopment)
        let heldout = (original + guards).filter { !isDevelopment($0) }
        let rows = evaluate(development, penalties: penalties)
        let best = rows.map(\.macroTop1).max()!
        let ties = rows.filter { $0.macroTop1 == best }.map(\.penalty)
        let selected = ties.min { abs($0 - legacy) < abs($1 - legacy) }!
        let comparison = selected == legacy ? [legacy] : [legacy, selected]
        return GridReport(selectedPenalty: selected, coLeaders: ties, grid: rows,
                          validation: evaluate(heldout, penalties: comparison),
                          originalRegression: evaluate(original, penalties: comparison))
    }

    private static func evaluate(_ queries: [Query], penalties: [Double]) -> [GridRow] {
        let engine = CandidateEngine()
        let configs = penalties.map { RankingExperiment(englishWordInsertionBits: $0, fullCoverageFirst: true) }
        var rows = penalties.map { GridRow(penalty: $0) }
        for query in queries {
            let candidates = engine.candidates(for: query.input, languages: both, now: Benchmark.fixedDate)
            let pool = CandidateRankingPool(candidates: candidates, model: nil)
            for i in configs.indices {
                let ranked = pool.ranked(using: configs[i])
                rows[i].record(ranked, for: query, group: query.kind)
            }
        }
        return rows
    }
}
