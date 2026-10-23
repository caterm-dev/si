import Foundation
import SICore

/// Synthetic, in-process candidate-generation measurements, not host-app latency measurements.
@main
enum SIBenchmark {
    struct Measurement: Encodable {
        let scenario: String
        let inputLength: Int
        let iterations: Int
        let candidates: Int
        let candidateFingerprint: String
        let maximumPersonalPhraseBytes: Int
        let medianMilliseconds: Double
        let p95Milliseconds: Double
        let maximumMilliseconds: Double
    }

    struct Report: Encodable {
        let measuredAt: Date
        let operatingSystem: String
        let learnedPreferences: Int
        let personalPhrases: Int
        let engineInitializationMilliseconds: Double
        let checksum: Int
        let measurements: [Measurement]
    }

    static func main() throws {
        if CommandLine.arguments.dropFirst().contains("--automatic-confirmation") {
            try AutomaticConfirmationBenchmark.run()
            return
        }
        if CommandLine.arguments.dropFirst().contains("--quality") {
            try RankingQuality.run()
            return
        }
        let previewsOnly = CommandLine.arguments.dropFirst().contains("--previews")
        // Small explicit runs are for smoke comparisons; the default measurement keeps 200 samples.
        let requestedIterations = ProcessInfo.processInfo.environment["SI_BENCHMARK_ITERATIONS"].flatMap(Int.init)
        let iterations = min(1_000, max(1, requestedIterations ?? 200))
        let warmups = min(10, max(1, iterations / 10))
        let now = Date.now
        let profile = LearningProfile(entries: (0..<LearningProfile.maximumEntries).map {
            LearnedPreference(input: "shi", text: "synthetic\($0)", language: .english, strength: 1, lastUsed: now)
        }, now: now)
        let initializationClock = ContinuousClock()
        let initializationStart = initializationClock.now
        let engine = CandidateEngine()
        let initializationDuration = initializationStart.duration(to: initializationClock.now).components
        let initializationMilliseconds = Double(initializationDuration.seconds) * 1_000
            + Double(initializationDuration.attoseconds) / 1e15
        let tokenProfile = LearningProfile(entries: Array(profile.entries.dropLast()) + [
            LearnedPreference(input: "shike", text: "食客", language: .simplifiedChinese, strength: 8, lastUsed: now),
        ], now: now)
        let dictionary = try UserDictionary(entries: (0..<UserDictionary.maximumEntries).map {
            try UserPhrase(input: "bench", text: "Synthetic phrase \($0)", language: .english)
        })
        let longDictionary = try UserDictionary(entries: (0..<UserDictionary.maximumEntries).map {
            try UserPhrase(input: $0 < 20 ? "a" : "bench",
                           text: $0 < 20 ? String(repeating: "x", count: 1_000) + "\($0)" : "Synthetic phrase \($0)",
                           language: .english)
        })
        let unicodeDictionary = try UserDictionary(entries: (0..<UserDictionary.maximumEntries).map {
            try UserPhrase(input: $0 < 20 ? "a" : "bench",
                           text: $0 < 20 ? String(repeating: "测试👩🏽‍💻", count: 40) + "\($0)" : "Synthetic phrase \($0)",
                           language: .simplifiedChinese)
        })
        let clock = ContinuousClock()
        var checksum = 0
        var measurements: [Measurement] = []
        let cases = [
            ("short", "shi"), ("ambiguous", "he"), ("partial", "niha"),
            ("phrase construction", "womenxuexizhongwen"),
            ("ambiguous syllable boundaries", "woxianganzhao"),
            ("bounded ambiguous cuts", String(repeating: "fangan", count: 10)),
            ("mixed", "woaiSwiftshurufa"),
            ("mixed deployment", "woxiangyaodeploy"),
            ("continuous English", "iwanttobuild"),
            ("whole homophones", "xianshi"),
            ("sentence word choice", "biruzhege"),
            ("Chinese unknown ending", String(repeating: "a", count: 58) + "qwerty"),
            ("long ambiguous composition", String(repeating: "shi", count: 20)),
            ("literal fallback beyond decoder limit", String(repeating: "q", count: 128)),
            ("personal phrase prefix at full capacity", "b"),
            ("dense known composition", String(repeating: "a", count: 64)),
            ("dense prefix with unknown tail", String(repeating: "a", count: 58) + "QwErTy"),
            ("bounded long personal expansions", String(repeating: "a", count: 20)),
            ("learned tokens in longer composition", "wo" + String(repeating: "shike", count: 3)),
            ("bounded Unicode personal expansions", String(repeating: "a", count: 20)),
            ("English broad prefix", "a"), ("English prefix", "sub"),
            ("English uppercase prefix", "SUB"), ("English exact", "subtitle"),
            ("English missing prefix", "zzzzzz"),
        ]
        for (name, input) in cases {
            let languages: Set<InputLanguage> = name.hasPrefix("English ") ? [.english]
                : name.hasPrefix("Chinese ") ? [.simplifiedChinese] : Set(InputLanguage.allCases)
            let activeDictionary = name == "bounded long personal expansions" ? longDictionary
                : name == "bounded Unicode personal expansions" ? unicodeDictionary : dictionary
            let activeProfile = name == "learned tokens in longer composition" ? tokenProfile : profile
            let generate: () -> [InputCandidate]
            if previewsOnly {
                var session = InputSession(engine: engine, candidateGeneration: .deferred)
                session.configure(languages: languages, learning: activeProfile, dictionary: activeDictionary)
                session.append(input)
                let request = session.pendingCandidateRequest!
                generate = { request.generatePreview().candidates }
            } else {
                generate = {
                    engine.candidates(for: input, languages: languages, learning: activeProfile,
                                      dictionary: activeDictionary)
                }
            }
            for _ in 0..<warmups {
                checksum += generate().count
            }
            var times: [Double] = []
            var candidateCount = 0
            var lastCandidates: [InputCandidate] = []
            for _ in 0..<iterations {
                let start = clock.now
                let candidates = generate()
                let duration = start.duration(to: clock.now).components
                times.append(Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15)
                checksum += candidates.count
                candidateCount = candidates.count
                lastCandidates = candidates
            }
            times.sort()
            measurements.append(Measurement(scenario: previewsOnly ? "provisional " + name : name,
                                            inputLength: input.count, iterations: times.count,
                                            candidates: candidateCount,
                                            candidateFingerprint: fingerprint(lastCandidates),
                                            maximumPersonalPhraseBytes: activeDictionary.entries.map { $0.text.utf8.count }.max() ?? 0,
                                            medianMilliseconds: times[times.count / 2],
                                            p95Milliseconds: times[Int(Double(times.count - 1) * 0.95)],
                                            maximumMilliseconds: times.last ?? 0))
        }
        // Compare the caller's edit path only. Deferred final resolution is outside this timed region;
        // its real search cost is measured by the candidate-generation scenarios above.
        let typingInput = "woaiSwiftshurufa"
        let generations: [InputSession.CandidateGeneration] = previewsOnly ? [] : [.synchronous, .deferred]
        for generation in generations {
            var times: [Double] = []
            var lastCandidates: [InputCandidate] = []
            for iteration in -3..<20 {
                var session = InputSession(engine: engine, candidateGeneration: generation)
                session.configure(languages: Set(InputLanguage.allCases), learning: profile, dictionary: dictionary)
                let start = clock.now
                for character in typingInput { session.append(String(character)) }
                let duration = start.duration(to: clock.now).components
                if iteration >= 0 {
                    times.append(Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15)
                }
                session.resolveCandidates()
                lastCandidates = session.candidates
                checksum += session.candidates.count
            }
            times.sort()
            measurements.append(Measurement(
                scenario: generation == .synchronous ? "synchronous typing edits" : "deferred typing edits",
                inputLength: typingInput.count, iterations: times.count, candidates: lastCandidates.count,
                candidateFingerprint: fingerprint(lastCandidates),
                maximumPersonalPhraseBytes: dictionary.entries.map { $0.text.utf8.count }.max() ?? 0,
                medianMilliseconds: times[times.count / 2],
                p95Milliseconds: times[Int(Double(times.count - 1) * 0.95)], maximumMilliseconds: times.last ?? 0))
        }
        let report = Report(measuredAt: now, operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                            learnedPreferences: profile.entries.count, personalPhrases: dictionary.entries.count,
                            engineInitializationMilliseconds: initializationMilliseconds,
                            checksum: checksum, measurements: measurements)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        print(String(decoding: try encoder.encode(report), as: UTF8.self))
    }

    /// Stable regression fingerprint of synthetic output/order/metadata, outside timed regions.
    private static func fingerprint(_ candidates: [InputCandidate]) -> String {
        var value: UInt64 = 14_695_981_039_346_656_037
        for candidate in candidates {
            let fields = [candidate.id, String(candidate.score), String(candidate.rankingScore.bitPattern), String(candidate.remainingInputScore.bitPattern),
                          String(candidate.isMixed), String(candidate.isUserPhrase), String(candidate.hasLiteralSegments),
                          String(candidate.hasCompletion), String(candidate.consumedInputCount ?? -1)]
            for field in fields {
                let bytes = Array(field.utf8)
                for shift in stride(from: 0, to: 64, by: 8) {
                    value = (value ^ UInt64((UInt64(bytes.count) >> shift) & 255)) &* 1_099_511_628_211
                }
                for byte in bytes { value = (value ^ UInt64(byte)) &* 1_099_511_628_211 }
            }
        }
        return String(value, radix: 16)
    }
}
