import Foundation
import Testing
@testable import SICore
@testable import SIPresentation

@MainActor
struct WindowRankingRegressionTests {
    private struct Query: Decodable {
        struct Choice: Decodable {
            let language: String
            let text: String
            let tokenSpelling: String?
            let bonus: Double
        }
        let id: String
        let input: String
        let context: String
        let languages: [InputLanguage]
        let references: [String]
        let priorChoices: [Choice]?
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SI_TEST_ENGINE_RESOURCE_DIRECTORY"] != nil))
    func regressionQueriesUseTheActualWindow() throws {
        // Reference positions in the window with the paired production snapshots.
        let expected = [
            "regression-english-fan": 28, "regression-english-ban": 20,
            "regression-english-pin": 9, "regression-english-run": 2,
            "regression-english-cannot": 2, "regression-context-number": 2,
        ]
        for query in try Self.queries() {
            let off = try Self.rank(query, correction: .off, learning: LearningProfile())
            let on = try Self.rank(query, correction: .conservative, learning: LearningProfile())
            #expect(off == (expected[query.id] ?? 1), "\(query.id) with correction off")
            #expect(on == (expected[query.id] ?? 1), "\(query.id) with conservative correction")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SI_TEST_ENGINE_RESOURCE_DIRECTORY"] != nil))
    func injectedPreferenceUsesItsOwnRegressionSlice() throws {
        let queries = try Self.queries()
        let river = try #require(queries.first { $0.id == "regression-context-river" })
        let now = Date(timeIntervalSince1970: 0)
        let choices = try #require(river.priorChoices)
        let profile = LearningProfile(entries: choices.map {
            LearnedPreference(input: $0.tokenSpelling ?? river.input, text: $0.text,
                              language: $0.language == "en" ? .english : .simplifiedChinese,
                              strength: $0.bonus, lastUsed: now, isMixed: $0.language == "mixed")
        }, now: now, retainsIndefinitely: true)
        let off = try Self.rank(river, correction: .off, learning: profile)
        let on = try Self.rank(river, correction: .conservative, learning: profile)
        #expect(off == 2)
        #expect(on == 2)
    }

    private static func queries() throws -> [Query] {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "eval/regression/window-ranking.jsonl")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let rows = try String(contentsOf: fixture, encoding: .utf8).split(separator: "\n").map {
            try decoder.decode(Query.self, from: Data($0.utf8))
        }
        try #require(!rows.isEmpty)
        #expect(Set(rows.map(\.id)).count == rows.count)
        return rows
    }

    private static func rank(_ query: Query, correction: CandidateEngine.PinyinCorrectionMode,
                             learning: LearningProfile) throws -> Int {
        let now = Date(timeIntervalSince1970: 0)
        var session = InputSession(engine: CandidateEngine(usesCoverageAdjustedOrder: false))
        session.configure(languages: Set(query.languages), learning: learning, now: now,
                          pinyinCorrectionMode: correction)
        session.setPrecedingText(query.context)
        session.append(query.input, now: now)
        var selection = CandidateSelection()
        selection.update(session.candidates)
        let index = selection.candidates.firstIndex {
            !$0.isLiteral && !$0.isPartial && query.references.contains($0.text)
        }
        return try #require(index, "\(query.id) must be selectable") + 1
    }
}
