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
    func sentenceBudgetStaysBoundedWhileTypingAndDeletingTheReportedTail() throws {
        for reranking in [false, true] {
            var session = InputSession(engine: CandidateEngine(usesCoverageAdjustedOrder: false))
            session.configure(languages: Set(InputLanguage.allCases), pinyinCorrectionMode: .conservative,
                              rerankingEnabled: reranking)
            var selection = CandidateSelection()
            session.append("wobuzhidaonishibushi")
            selection.update(session.candidates)
            #expect(selection.candidates.filter { !$0.isLiteral && !$0.isPartial }.count == 2)
            for suffix in ["yige", "xiao", "de", "x"] {
                session.append(suffix)
                selection.update(session.candidates)
                #expect(selection.candidates.filter { !$0.isLiteral && !$0.isPartial }.count == 1)
                #expect(selection.candidates.last?.text == session.buffer)
            }
            #expect(session.candidates.filter { !$0.isLiteral && !$0.isPartial }.count > 3)
            let selected = try #require(selection.candidate(number: 1))
            #expect(selected.hasCompletion && selected.text.hasPrefix("我不知道你是不是一个小的"))
            var submitted = session
            let commit = submitted.commitResult(selected, reason: selection.confirmationReason(for: selected))
            #expect(commit.text == selected.text && commit.input == session.buffer && submitted.buffer.isEmpty)
            for edit in ["delete", "xi", "delete", "delete"] {
                if edit == "delete" { session.deleteBackward() } else { session.append(edit) }
                selection.update(session.candidates)
                #expect(selection.candidates.filter { !$0.isLiteral && !$0.isPartial }.count == 1)
                #expect(selection.candidates.last?.text == session.buffer)
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SI_TEST_ENGINE_RESOURCE_DIRECTORY"] != nil))
    func earlierCorrectionSurvivesTypingAndDeletingAnIncompleteTail() throws {
        let stem = "wobuzhdaonishibushiyige"
        let expected = "我不知道你是不是一个"
        for reranking in [false, true] {
            var session = InputSession(engine: CandidateEngine(usesCoverageAdjustedOrder: false))
            session.configure(languages: Set(InputLanguage.allCases), pinyinCorrectionMode: .conservative,
                              rerankingEnabled: reranking)
            session.append(stem)
            var selection = CandidateSelection()
            selection.update(session.candidates)
            #expect(selection.selected?.text == expected && selection.selected?.isPinyinCorrection == true)
            for tail in ["x", "i", "n"] {
                session.append(tail)
                selection.update(session.candidates)
                let first = try #require(selection.candidate(number: 1))
                #expect(first.text.hasPrefix(expected) && first.isPinyinCorrection && !first.canLearn)
                #expect(first.confirmationBoundaries.isEmpty)
                #expect(first.hasCompletion == (tail == "x"))
                var literal = session
                #expect(literal.commitResult(reason: .literal).text == session.buffer)
            }
            #expect(selection.selected?.text == expected + "新")
            for _ in 0..<3 {
                session.deleteBackward()
                selection.update(session.candidates)
                #expect(selection.selected?.text.hasPrefix(expected) == true)
                #expect(selection.selected?.isPinyinCorrection == true)
            }
            #expect(session.buffer == stem && selection.selected?.text == expected)
            session.append("x")
            selection.update(session.candidates)
            let first = try #require(selection.candidate(number: 1))
            #expect(first.text == expected + "新" && first.hasCompletion)
            let commit = session.commitResult(first, reason: selection.confirmationReason(for: first))
            #expect(commit.text == expected + "新" && commit.input == stem + "x")
            #expect(commit.reason == .explicitSelection && session.buffer.isEmpty)
        }
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
