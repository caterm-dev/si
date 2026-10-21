import Foundation
import SICore

/// Fixed synthetic text only. Paired Release measurements include evidence extraction on the worker;
/// edit and delivery measurements exclude decoding. This does not measure native host latency.
enum AutomaticConfirmationBenchmark {
    enum ValidationError: Error {
        case candidateResultsChanged
        case incorrectCommittedPrefixes(Int)
        case automaticConfirmationNeverActivated
    }
    struct Timing: Encodable {
        let medianMilliseconds: Double
        let p95Milliseconds: Double

        init(_ samples: [Double]) {
            let values = samples.sorted()
            medianMilliseconds = values[values.count / 2]
            p95Milliseconds = values[Int(Double(values.count - 1) * 0.95)]
        }
    }

    struct Search: Encodable {
        let input: String
        let withoutConfirmation: Timing
        let withConfirmation: Timing
        let appendOnCaller: Timing
        let deliveryAndDecisionOnCaller: Timing
        let candidateOrderAndBytesUnchanged: Bool
    }

    struct Example: Encodable {
        let input: String
        let expected: String?
        let languages: [String]
        let deliveryEveryCharacters: Int
        let committedWhileTyping: String
        let committedOnPause: String
        let editableRemainder: String
        let finalLeadingCandidate: String
        let correctCommittedPrefix: Bool
    }

    struct Report: Encodable {
        let measuredAt: Date
        let searches: [Search]
        let examples: [Example]
    }

    static func run() throws {
        let engine = CandidateEngine()
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let languages = Set(InputLanguage.allCases)
        let inputs = ["nihaopengyou", "womenxuexizhongwen", "wojintianxiangqugongzuo",
                      "nihaopengyouxuexizhongwen", String(repeating: "shi", count: 20), "MySwiftType"]
        var searches: [Search] = []
        for input in inputs {
            var off = InputSession(engine: engine, candidateGeneration: .deferred)
            off.configure(languages: languages)
            off.append(input, now: now)
            let offRequest = off.pendingCandidateRequest!
            var on = InputSession(engine: engine, candidateGeneration: .deferred)
            on.configure(languages: languages, automaticConfirmationEnabled: true)
            on.append(input, now: now)
            let onRequest = on.pendingCandidateRequest!
            var offTimes: [Double] = []
            var onTimes: [Double] = []
            var edits: [Double] = []
            var deliveries: [Double] = []
            var unchanged = true
            for iteration in -3..<40 {
                var baseline: CandidateResult!
                var result: CandidateResult!
                // Alternate order to reduce warm-cache and scheduling bias.
                let offTime: Double, onTime: Double
                if iteration.isMultiple(of: 2) {
                    offTime = measure { baseline = offRequest.generate() }
                    onTime = measure { result = onRequest.generate() }
                } else {
                    onTime = measure { result = onRequest.generate() }
                    offTime = measure { baseline = offRequest.generate() }
                }
                unchanged = unchanged && zip(baseline.candidates, result.candidates).allSatisfy {
                    $0.id == $1.id && $0.rankingScore == $1.rankingScore && $0.text.utf8.elementsEqual($1.text.utf8)
                } && baseline.candidates.count == result.candidates.count
                var session = InputSession(engine: engine, candidateGeneration: .deferred)
                session.configure(languages: languages, automaticConfirmationEnabled: true)
                let editTime = measure { session.append(input, now: now) }
                let fresh = session.pendingCandidateRequest!.generate()
                let deliveryTime = measure {
                    _ = session.accept(fresh, now: now)
                    _ = session.automaticallyConfirm(now: now)
                }
                if iteration >= 0 {
                    offTimes.append(offTime)
                    onTimes.append(onTime)
                    edits.append(editTime)
                    deliveries.append(deliveryTime)
                }
            }
            searches.append(Search(input: input, withoutConfirmation: Timing(offTimes), withConfirmation: Timing(onTimes),
                                   appendOnCaller: Timing(edits), deliveryAndDecisionOnCaller: Timing(deliveries),
                                   candidateOrderAndBytesUnchanged: unchanged))
        }
        var fixtures: [(String, String?)] = [
            ("nihaopengyou", "你好朋友"),
            ("womenxuexizhongwen", "我们学习中文"),
            ("nihaopengyouxuexizhongwen", "你好朋友学习中文"),
            ("wojintianxiangqugongzuo", "我今天想去工作"),
            ("jintiantianqihenhao", "今天天气很好"),
            ("woaizhongguorenmin", "我爱中国人民"),
            ("nengxiangbanfayouhuama", "能想办法优化吗"),
            ("bangwozaixieyige", "帮我再写一个"),
            ("zhegeshurufahenhaoyong", "这个输入法很好用"),
            ("woxiangxuexizhongwen", "我想学习中文"),
            ("nihao", nil), ("shi", nil), ("he", nil), ("nihaotitle", nil),
            ("user@example.com", nil), ("nihao.test", nil), ("MySwiftType", nil),
            ("helloworld", nil), ("nihaoQwErTy", nil), ("woaiSwiftshurufa", nil),
        ]
        // These existing fixtures are regression/development data, including an already inspected
        // historical holdout. They are not an independent accuracy estimate.
        for path in ["Data/Ranking/evaluation.json", "Data/Ranking/holdout.json", "Data/Ranking/phonetic-regressions.json"] {
            let records = try JSONDecoder().decode([RankingQuality.Example].self,
                                                   from: Data(contentsOf: URL(fileURLWithPath: path)))
            for record in records where !fixtures.contains(where: { $0.0 == record.input }) {
                fixtures.append((record.input, record.expected))
            }
        }
        var examples: [Example] = []
        for (fixtureIndex, fixture) in fixtures.enumerated() {
            let (input, expected) = fixture
            for activeLanguages: Set<InputLanguage> in [languages, [.simplifiedChinese]] {
                for stride in [1, 3, 100] {
                    var session = InputSession(engine: engine, candidateGeneration: .deferred)
                    session.configure(languages: activeLanguages, automaticConfirmationEnabled: true)
                    var typing = ""
                    for (offset, character) in input.enumerated() {
                        let time = now.addingTimeInterval(Double(offset) * 0.08)
                        session.append(String(character), now: time)
                        if (offset + 1).isMultiple(of: stride) || offset + 1 == input.count {
                            _ = session.accept(session.pendingCandidateRequest!.generate(), now: time)
                            if let commit = session.automaticallyConfirm(now: time) { typing += commit.text }
                        }
                    }
                    if let request = session.pendingCandidateRequest { _ = session.accept(request.generate(), now: now.addingTimeInterval(10)) }
                    let finalLeader = session.candidates.first?.text ?? ""
                    let pause = session.automaticallyConfirm(now: now.addingTimeInterval(20), afterPause: true)?.text ?? ""
                    let committed = typing + pause
                    examples.append(Example(input: input, expected: expected, languages: activeLanguages.map(\.rawValue).sorted(),
                                            deliveryEveryCharacters: stride,
                                            committedWhileTyping: typing, committedOnPause: pause, editableRemainder: session.buffer,
                                            finalLeadingCandidate: finalLeader,
                                            correctCommittedPrefix: expected.map { $0.hasPrefix(committed) } ?? committed.isEmpty))
                }
            }
            if (fixtureIndex + 1).isMultiple(of: 20) || fixtureIndex + 1 == fixtures.count {
                let progress = "Automatic confirmation: evaluated \(fixtureIndex + 1)/\(fixtures.count) synthetic fixtures.\n"
                try FileHandle.standardError.write(contentsOf: Data(progress.utf8))
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let report = try encoder.encode(Report(measuredAt: .now, searches: searches, examples: examples))
        try FileHandle.standardOutput.write(contentsOf: report + Data("\n".utf8))
        guard searches.allSatisfy(\.candidateOrderAndBytesUnchanged) else { throw ValidationError.candidateResultsChanged }
        let incorrect = examples.filter { !$0.correctCommittedPrefix }.count
        guard incorrect == 0 else { throw ValidationError.incorrectCommittedPrefixes(incorrect) }
        guard examples.contains(where: { !$0.committedWhileTyping.isEmpty }),
              examples.contains(where: { !$0.committedOnPause.isEmpty }) else {
            throw ValidationError.automaticConfirmationNeverActivated
        }
    }

    private static func measure(_ body: () -> Void) -> Double {
        let clock = ContinuousClock()
        let start = clock.now
        body()
        let duration = start.duration(to: clock.now).components
        return Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15
    }
}
