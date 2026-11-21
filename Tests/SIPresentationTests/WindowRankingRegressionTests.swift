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
            let bonus: Double
        }
        let id: String
        let input: String
        let context: String
        let languages: [InputLanguage]
        let references: [String]
        let priorChoices: [Choice]?
        let knownTop1Miss: Bool?
        let knownTop4Miss: Bool?
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SI_TEST_ENGINE_RESOURCE_DIRECTORY"] != nil))
    func regressionQueriesUseTheActualWindow() throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "eval/regression/window-ranking.jsonl")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let queries = try String(contentsOf: fixture, encoding: .utf8).split(separator: "\n").map {
            try decoder.decode(Query.self, from: Data($0.utf8))
        }
        try #require(!queries.isEmpty)
        #expect(Set(queries.map(\.id)).count == queries.count)

        let now = Date(timeIntervalSince1970: 0)
        for query in queries {
            var session = InputSession(candidateGeneration: .deferred)
            let learning = LearningProfile(entries: (query.priorChoices ?? []).map {
                LearnedPreference(input: query.input, text: $0.text,
                                  language: $0.language == "en" ? .english : .simplifiedChinese,
                                  strength: $0.bonus, lastUsed: now)
            }, now: now, retainsIndefinitely: true)
            session.configure(languages: Set(query.languages), learning: learning, now: now,
                              experimentalRankingEnabled: true)
            session.setPrecedingText(query.context)
            session.append(query.input, now: now)
            let request = try #require(session.pendingCandidateRequest)
            let result = request.generate(useExperimentalRanking: true)
            var selection = CandidateSelection()
            selection.update(result.candidates)
            let rank = selection.candidates.firstIndex {
                !$0.isLiteral && !$0.isPartial && query.references.contains($0.text)
            }.map { $0 + 1 }
            #expect(rank != nil, "\(query.id) must be selectable")
            if query.knownTop1Miss == true {
                withKnownIssue("Existing first-choice miss for \(query.id)", isIntermittent: true) {
                    #expect(rank == 1)
                }
            } else {
                #expect(rank == 1, "\(query.id)")
            }
            if query.knownTop4Miss == true {
                withKnownIssue("Existing first-four miss for \(query.id)", isIntermittent: true) {
                    #expect((rank ?? Int.max) <= 4)
                }
            } else {
                #expect((rank ?? Int.max) <= 4, "\(query.id)")
            }
        }
    }
}
