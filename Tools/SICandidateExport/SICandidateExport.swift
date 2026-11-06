import Foundation
import SICore

/// Explicit offline export of authored benchmark queries; never observes host input.
@main
enum SICandidateExport {
    struct Request: Decodable {
        let id: String
        let input: String
        let context: [String]?
    }

    struct Candidate: Encodable {
        let identity: String
        let text: String
        let language: String
        let mixed: Bool
        let score: Double
    }

    struct Response: Encodable {
        let id: String
        let input: String
        let candidates: [Candidate]
        let totalEligible: Int
        let excludedPartialOrCompletion: Int
        let literalAvailable: Bool
    }

    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.count == 2 && arguments[0] == "--features" {
            try exportFeatures(modelURL: URL(fileURLWithPath: arguments[1]))
            return
        }
        guard arguments.isEmpty else {
            throw NSError(domain: "SICandidateExport", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Read authored {id,input,context?} JSONL on stdin. Use --features TRAIN_ONLY_MODEL for CSV.",
            ])
        }
        let engine = CandidateEngine()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let now = Date(timeIntervalSince1970: 0)
        while let line = readLine() {
            let request = try JSONDecoder().decode(Request.self, from: Data(line.utf8))
            let all = engine.candidates(for: request.input, languages: [.simplifiedChinese, .english], now: now)
            let eligible = all.filter {
                !$0.isLiteral && !$0.isPartial && !$0.hasCompletion && !$0.hasLiteralSegments && !$0.isPunctuation
            }
            // Keep language-aware identities, even when two candidates have identical bytes.
            let response = Response(
                id: request.id, input: request.input,
                candidates: eligible.prefix(32).map {
                    Candidate(identity: $0.id, text: $0.text, language: $0.language!.rawValue,
                              mixed: $0.isMixed, score: $0.rankingScore)
                },
                totalEligible: eligible.count,
                excludedPartialOrCompletion: all.filter { $0.isPartial || $0.hasCompletion }.count,
                literalAvailable: all.contains { $0.isLiteral && Array($0.text.utf8) == Array(request.input.utf8) }
            )
            FileHandle.standardOutput.write(try encoder.encode(response))
            FileHandle.standardOutput.write(Data([10]))
        }
    }

    private static func exportFeatures(modelURL: URL) throws {
        guard let model = try KenLMModel.openBenchmark(modelURL) else {
            throw NSError(domain: "SICandidateExport", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Expected the pinned train-only clean2 model."
            ])
        }
        let engine = CandidateEngine()
        let names = ["coverage", "is_full_coverage", "is_full_match", "has_completion", "num_words",
                     "avg_word_len", "num_single_char_words", "log_freq_sum", "log_freq_min",
                     "lm_bits", "lm_bits_per_word", "lm_oov_ratio", "input_is_dictionary_word",
                     "base_score", "language_zh", "language_en", "language_mixed", "language_literal"]
        let relative = ["rank", "delta_from_best", "delta_from_mean", "zscore"]
        let header = ["schema", "model_sha256", "query_id", "group_id", "input", "candidate_id", "text", "language"]
            + names + names.flatMap { name in relative.map { name + "_" + $0 } }
        print(header.joined(separator: ","))
        while let line = readLine() {
            let request = try JSONDecoder().decode(Request.self, from: Data(line.utf8))
            let all = engine.candidates(for: request.input, languages: [.simplifiedChinese, .english],
                                        now: Date(timeIntervalSince1970: 0))
            let pool = CandidateRankingPool(candidates: all, model: model, context: request.context ?? [])
            let rows = zip(all, pool.features(input: request.input)).sorted {
                ($0.0.consumedInputCount ?? Int.max, $0.0.id) < ($1.0.consumedInputCount ?? Int.max, $1.0.id)
            }
            for (candidate, features) in rows {
                let group = request.id + (candidate.consumedInputCount.map { "/prefix/\($0)" } ?? "/full")
                var fields = ["si-rank-v1", model.sha256, request.id, group, request.input,
                              features.identity, features.text, features.language]
                fields += names.map { features.values[$0].map { String($0) } ?? "" }
                for name in names {
                    if let row = features.relative[name] {
                        fields += [String(row.rank), String(row.deltaFromBest), String(row.deltaFromMean), String(row.zScore)]
                    } else { fields += ["", "", "", ""] }
                }
                print(fields.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ","))
            }
        }
    }

}
