import Foundation
import SICore

enum KenLMRankingBenchmark {
    struct Query: Decodable {
        let id: String
        let input: String
        let expected: String
        let context: [String]
        let kind: String
        let bucket: String
    }

    struct Profile: Codable {
        let name: String
        var lm = 0.0
        var wip = 20 / log(2.0)
        var coverage = false
        var insertionOnly = false
        var englishWip: Double? = nil

        func configuration(_ model: KenLMModel) -> RankingExperiment {
            RankingExperiment(model: lm == 0 ? nil : model, languageModelWeight: lm,
                              englishLanguageModelWeight: 0, frequencyWeight: 1, wordInsertionBits: wip,
                              englishWordInsertionBits: englishWip ?? RankingExperiment.defaultEnglishWordInsertionBits,
                              fullCoverageFirst: coverage)
        }
    }

    struct Tuning: Codable {
        let modelSHA256: String
        let queries: Int
        let selected: [Profile]
        let coLeaders: [String: [GridRow]]?
        let grid: [GridRow]
    }

    struct GridRow: Codable {
        let profile: Profile
        let top1: Int
    }

    private struct EnglishSelection: Decodable {
        let selectedPenalty: Double
    }

    struct Metrics: Encodable {
        var queries = 0
        var top1 = 0
        var top5 = 0
        var poolRecall = 0
        var characterErrors = 0
        var characters = 0
        var latencyMicroseconds: [Double] = []

        mutating func record(_ query: Query, top: ArraySlice<InputCandidate>, reachable: Bool, micros: Double) {
            queries += 1
            top1 += top.first.map { Self.correct($0, query.expected) } == true ? 1 : 0
            top5 += top.contains { Self.correct($0, query.expected) } ? 1 : 0
            poolRecall += reachable ? 1 : 0
            characterErrors += Self.distance(top.first?.text ?? "", query.expected)
            characters += query.expected.count
            latencyMicroseconds.append(micros)
        }

        func encode(to encoder: Encoder) throws {
            let sorted = latencyMicroseconds.sorted()
            func percentile(_ p: Double) -> Double? {
                guard !sorted.isEmpty else { return nil }
                return sorted[max(0, Int(ceil(p * Double(sorted.count))) - 1)]
            }
            struct Row: Encodable {
                let queries: Int
                let top1: Int
                let top5: Int
                let poolRecall: Int
                let characterErrors: Int
                let characters: Int
                let p50Microseconds: Double?
                let p95Microseconds: Double?
            }
            try Row(queries: queries, top1: top1, top5: top5, poolRecall: poolRecall,
                    characterErrors: characterErrors, characters: characters,
                    p50Microseconds: percentile(0.5), p95Microseconds: percentile(0.95)).encode(to: encoder)
        }

        static func correct(_ candidate: InputCandidate, _ expected: String) -> Bool {
            !candidate.isLiteral && !candidate.isPartial && candidate.text.utf8.elementsEqual(expected.utf8)
        }

        private static func distance(_ left: String, _ right: String) -> Int {
            let a = Array(left), b = Array(right)
            if a == b { return 0 }
            var row = Array(0...b.count)
            for (i, x) in a.enumerated() {
                var next = [i + 1]
                for (j, y) in b.enumerated() {
                    next.append(min(row[j + 1] + 1, next[j] + 1, row[j] + (x == y ? 0 : 1)))
                }
                row = next
            }
            return row[b.count]
        }
    }

    struct Evaluation: Encodable {
        let modelSHA256: String
        let profiles: [Profile]
        let groups: [String: [String: Metrics]]
    }

    static let insertions: [Double] = [-4, 0, 2, 4, 6, 8, 10, 12, 16, 22, 28.85]
    static let weights = [0.05, 0.1, 0.15, 0.25, 0.5, 1.0, 2.0]
    static let fixedDate = Date(timeIntervalSince1970: 0)

    static func run(_ args: [String]) throws {
        guard args.count >= 3,
              ["tune", "test", "strict", "english", "english-final", "hard", "recall"].contains(args[0]),
              let model = try KenLMModel.openBenchmark(URL(fileURLWithPath: args[1])) else {
            throw invalid("Use --kenlm MODE TRAIN_ONLY_MODEL DATASET [HARD_CASES_TSV] [ENGLISH_GRID_JSON] [TUNING_JSON].")
        }
        let mode = args[0]
        let directory = URL(fileURLWithPath: args[2], isDirectory: true)
        let engine = CandidateEngine()
        let englishMode = mode == "english" || mode == "english-final"
        let languages: Set<InputLanguage> = englishMode ? [.simplifiedChinese, .english] : [.simplifiedChinese]
        // Warm dictionary initialization separately from per-query timing.
        _ = engine.candidates(for: englishMode ? "into" : "nihao", languages: languages, now: fixedDate)

        if mode == "recall" {
            try encode(recall(directory: directory, engine: engine))
            return
        }
        if mode == "tune" {
            try encode(tune(directory: directory, model: model, engine: engine, languages: languages))
            return
        }

        let argumentCounts = mode == "hard" ? [5, 6] : mode == "english-final" ? [5] : [4]
        guard argumentCounts.contains(args.count), let tuningPath = args.last else {
            throw invalid("Expected the frozen Chinese tuning result as the final argument.")
        }
        let tuning = try JSONDecoder().decode(Tuning.self, from: Data(contentsOf: URL(fileURLWithPath: tuningPath)))
        guard tuning.modelSHA256 == model.sha256 else { throw invalid("Tuning model identity differs.") }
        guard let combined = tuning.selected.first(where: { $0.name == "lm_coverage" }) else {
            throw invalid("Missing selected combined LM and coverage profile.")
        }

        var englishPenalty: Double?
        if mode == "english-final" || args.count == 6 {
            let path = URL(fileURLWithPath: args[args.count - 2])
            englishPenalty = try JSONDecoder().decode(EnglishSelection.self, from: Data(contentsOf: path)).selectedPenalty
        }
        if mode == "hard" {
            var profile = combined
            profile.englishWip = englishPenalty
            let coverageOnly = RankingExperiment(
                englishWordInsertionBits: englishPenalty ?? RankingExperiment.defaultEnglishWordInsertionBits,
                fullCoverageFirst: true)
            try encode(hardCases(URL(fileURLWithPath: args[3]), coverageOnly: coverageOnly,
                                 combined: profile.configuration(model)))
            return
        }

        var profiles = tuning.selected
        if englishMode {
            guard let selected = tuning.selected.first(where: { $0.name == "lm" }) else {
                throw invalid("Missing selected LM profile.")
            }
            profiles = [Profile(name: "legacy"), Profile(name: "coverage", coverage: true), selected,
                        Profile(name: "lm_coverage", lm: selected.lm, wip: selected.wip, coverage: true),
                        Profile(name: "app_lm_coverage", lm: combined.lm, wip: combined.wip, coverage: true)]
            if let englishPenalty {
                profiles += [Profile(name: "coverage_en_wip", coverage: true, englishWip: englishPenalty),
                             Profile(name: "combined_en_wip", lm: combined.lm, wip: combined.wip,
                                     coverage: true, englishWip: englishPenalty)]
            }
        }
        try encode(evaluate(mode: englishMode ? "english" : mode, directory: directory, model: model,
                            engine: engine, languages: languages, profiles: profiles))
    }

    private struct RecallRow: Encodable {
        let id: String
        let bucket: String
        let reachable: Bool
        let probe: PinyinDecoder.GoldLatticeProbe?
    }

    private static func recall(directory: URL, engine: CandidateEngine) throws -> [RecallRow] {
        let queries = try read(directory.appendingPathComponent("test.jsonl")).filter { $0.kind == "whole" }
        return queries.enumerated().map { index, query in
            let candidates = engine.candidates(for: query.input, languages: [.simplifiedChinese], now: fixedDate)
            let reachable = candidates.contains { Metrics.correct($0, query.expected) }
            let probe = reachable ? nil : PinyinDecoder.standard.probeGoldLattice(for: query.input, gold: query.expected)
            if index % 1_000 == 0 { progress("recall \(index)/\(queries.count)") }
            return RecallRow(id: query.id, bucket: query.bucket, reachable: reachable, probe: probe)
        }
    }

    private static func tune(directory: URL, model: KenLMModel, engine: CandidateEngine,
                             languages: Set<InputLanguage>) throws -> Tuning {
        var profiles = [Profile(name: "legacy"), Profile(name: "coverage", coverage: true)]
        profiles += insertions.map { Profile(name: "insertion", wip: $0, insertionOnly: true) }
        for coverage in [false, true] {
            for weight in weights {
                for wip in insertions {
                    profiles.append(Profile(name: coverage ? "lm_coverage" : "lm", lm: weight, wip: wip, coverage: coverage))
                }
            }
        }
        let configs = profiles.map { $0.configuration(model) }
        var hits = Array(repeating: 0, count: profiles.count)
        let queries = try read(directory.appendingPathComponent("dev.jsonl"))
        for (index, query) in queries.enumerated() {
            let candidates = engine.candidates(for: query.input, languages: languages, now: fixedDate)
            let pool = CandidateRankingPool(candidates: candidates, model: model, context: query.context)
            for i in profiles.indices {
                if let first = pool.first(using: configs[i], insertionOnly: profiles[i].insertionOnly),
                   Metrics.correct(first, query.expected) { hits[i] += 1 }
            }
            if index % 2_000 == 0 { progress("dev \(index)/\(queries.count)") }
        }
        let rows = zip(profiles, hits).map { GridRow(profile: $0.0, top1: $0.1) }
        let groups = Dictionary(grouping: rows, by: \.profile.name)
        let coLeaders = groups.mapValues { group in
            let maximum = group.map(\.top1).max()
            return group.filter { $0.top1 == maximum }.sorted { a, b in
                if a.profile.lm != b.profile.lm { return a.profile.lm < b.profile.lm }
                return abs(a.profile.wip - 28.85) < abs(b.profile.wip - 28.85)
            }
        }
        let selected = ["legacy", "coverage", "insertion", "lm", "lm_coverage"].compactMap {
            coLeaders[$0]?.first?.profile
        }
        return Tuning(modelSHA256: model.sha256, queries: queries.count, selected: selected, coLeaders: coLeaders, grid: rows)
    }

    private static func evaluate(mode: String, directory: URL, model: KenLMModel, engine: CandidateEngine,
                                 languages: Set<InputLanguage>, profiles: [Profile]) throws -> Evaluation {
        let queries = try read(directory.appendingPathComponent(mode + ".jsonl"))
        let configs = profiles.map { $0.configuration(model) }
        var stats: [String: [String: Metrics]] = [:]
        let clock = ContinuousClock()
        for (index, query) in queries.enumerated() {
            let start = clock.now
            let candidates = engine.candidates(for: query.input, languages: languages, now: fixedDate)
            let generation = micros(start.duration(to: clock.now))
            let reachable = candidates.contains { Metrics.correct($0, query.expected) }
            var pools: [Bool: (CandidateRankingPool, Double)] = [:]
            for (i, profile) in profiles.enumerated() {
                let rankStart = clock.now
                let ranked: [InputCandidate]
                let poolTime: Double
                if profile.name == "legacy" {
                    ranked = candidates
                    poolTime = 0
                } else {
                    let useLM = profile.lm != 0
                    if pools[useLM] == nil {
                        let started = clock.now
                        let pool = CandidateRankingPool(candidates: candidates, model: useLM ? model : nil,
                                                        context: query.context)
                        pools[useLM] = (pool, micros(started.duration(to: clock.now)))
                    }
                    let pair = pools[useLM]!
                    let scoring = clock.now
                    ranked = pair.0.ranked(using: configs[i], insertionOnly: profile.insertionOnly)
                    poolTime = pair.1 - micros(rankStart.duration(to: scoring))
                }
                let top = CandidateShortlist.candidates(from: ranked).prefix(5)
                let elapsed = generation + poolTime + micros(rankStart.duration(to: clock.now))
                for group in ["all", query.kind, "\(query.kind)/\(query.bucket)"] {
                    stats[profile.name, default: [:]][group, default: Metrics()]
                        .record(query, top: top, reachable: reachable, micros: elapsed)
                }
            }
            if index % 2_000 == 0 { progress("\(mode) \(index)/\(queries.count)") }
        }
        return Evaluation(modelSHA256: model.sha256, profiles: profiles, groups: stats)
    }

    private struct HardResult: Encodable {
        let input: String
        let expected: String
        let englishOnly: String?
        let bilingual: String?
        let passed: Bool?
        let bilingualWithLM: String?
        let passedWithLM: Bool?
    }

    private static func hardCases(_ url: URL, coverageOnly: RankingExperiment,
                                  combined: RankingExperiment) throws -> [HardResult] {
        let data = try String(contentsOf: url, encoding: .utf8)
        let engine = CandidateEngine(rankingExperiment: coverageOnly)
        let combinedEngine = CandidateEngine(rankingExperiment: combined)
        let bilingualLanguages: Set<InputLanguage> = [.english, .simplifiedChinese]
        return try data.split(separator: "\n").map { line in
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count == 2, !columns[0].isEmpty else { throw invalid("Invalid hard-case TSV row.") }
            let input = String(columns[0]), expected = String(columns[1])
            func top(_ engine: CandidateEngine, _ languages: Set<InputLanguage>) -> InputCandidate? {
                CandidateShortlist.candidates(from: engine.candidates(for: input, languages: languages, now: fixedDate)).first
            }
            let english = top(engine, [.english]), bilingual = top(engine, bilingualLanguages)
            let bilingualWithLM = top(combinedEngine, bilingualLanguages)
            let passed = [english, bilingual].allSatisfy { $0.map { Metrics.correct($0, expected) } ?? false }
            return HardResult(input: input, expected: expected, englishOnly: english?.text,
                              bilingual: bilingual?.text, passed: expected.isEmpty ? nil : passed,
                              bilingualWithLM: bilingualWithLM?.text,
                              passedWithLM: expected.isEmpty ? nil : bilingualWithLM.map { Metrics.correct($0, expected) } ?? false)
        }
    }

    static func read(_ url: URL) throws -> [Query] {
        let data = try String(contentsOf: url, encoding: .utf8)
        let decoder = JSONDecoder()
        return try data.split(separator: "\n").map { try decoder.decode(Query.self, from: Data($0.utf8)) }
    }

    static func encode(_ value: some Encodable) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(value), as: UTF8.self))
    }

    static func progress(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }

    private static func micros(_ value: Duration) -> Double {
        Double(value.components.seconds) * 1e6 + Double(value.components.attoseconds) / 1e12
    }

    private static func invalid(_ message: String) -> NSError {
        NSError(domain: "KenLMRankingBenchmark", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
