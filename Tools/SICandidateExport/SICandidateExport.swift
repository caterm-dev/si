import Foundation
import SICore

/// Explicit offline export of authored benchmark queries; never observes host input.
@main
enum SICandidateExport {
    struct Request: Decodable {
        let id: String
        let input: String
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
        guard CommandLine.arguments.count == 1 else {
            throw NSError(domain: "SICandidateExport", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Read authored {id,input} JSONL on stdin; emit up to 32 full candidates on stdout.",
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
}
