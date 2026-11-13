import Foundation
import Testing
@testable import SICore

struct ChineseFrequencyRankingTests {
    @Test(arguments: ["taiguo", "tai'guo"])
    func thailandAndItsHomophoneRemainSelectable(input: String) throws {
        for languages: Set<InputLanguage> in [[.simplifiedChinese], Set(InputLanguage.allCases)] {
            var session = InputSession(candidateGeneration: .deferred)
            session.configure(languages: languages)
            session.append(input)
            let request = try #require(session.pendingCandidateRequest)
            for candidates in [request.generatePreview().candidates, request.generate().candidates] {
                let matches = candidates.filter {
                    $0.language == .simplifiedChinese && !$0.isPartial && ($0.text == "泰国" || $0.text == "太过")
                }
                #expect(Set(matches.map(\.text)) == ["泰国", "太过"])
            }
        }
    }

    @Test func directAndPrefixChoicesUseTheSameLexicalScore() throws {
        let engine = CandidateEngine()
        for input in ["shangci", "shang'ci"] {
            for languages: Set<InputLanguage> in [[.simplifiedChinese], Set(InputLanguage.allCases)] {
                let direct = try #require(engine.candidates(for: input, languages: languages).first {
                    $0.text == "上次" && !$0.isPartial
                })
                let requestInput = input + "bi"
                for values in [engine.candidates(for: requestInput, languages: languages),
                               engine.previewCandidates(for: requestInput, languages: languages, learning: LearningProfile(),
                                   dictionary: UserDictionary(), now: .now, context: nil)] {
                    let prefix = try #require(values.first { $0.text == "上次" && $0.consumedInputCount == input.count })
                    #expect(abs(prefix.rankingScore - direct.rankingScore) < 1e-12)
                    #expect(values.last?.text == requestInput && values.last?.isLiteral == true)
                }
            }
        }
    }

    @Test func comparisonPhraseCanBeSelectedInBothSearchStages() throws {
        for input in ["heshangcibi", "he'shang'ci'bi"] {
            for languages: Set<InputLanguage> in [[.simplifiedChinese], Set(InputLanguage.allCases)] {
                var session = InputSession(candidateGeneration: .deferred)
                session.configure(languages: languages)
                session.append(input)
                let request = try #require(session.pendingCandidateRequest)
                let preview = request.generatePreview()
                let full = request.generate()
                for values in [preview.candidates, full.candidates] {
                    let phrase = try #require(values.first { $0.text == "和上次比" && !$0.isPartial })
                    #expect(!phrase.isMixed && !phrase.isUserPhrase)
                    #expect(values.contains { $0.text == "和尚刺鼻" && !$0.isPartial })
                    #expect(values.last?.text == input && values.last?.isLiteral == true)
                }
                #expect(session.accept(full) == true)
                let selected = try #require(session.candidates.first { $0.text == "和上次比" && !$0.isPartial })
                let commit = session.commitResult(selected, reason: .explicitSelection)
                #expect(commit.text == "和上次比" && commit.input == input)
                #expect(session.buffer.isEmpty)
            }
        }
    }

    @Test func frequentNaturalWordsBeatCrossBoundaryFragmentsInBothSearchStages() throws {
        for input in ["nawomenzaichaxun", "na'wo'men'zai'cha'xun"] {
            for languages: Set<InputLanguage> in [[.simplifiedChinese], Set(InputLanguage.allCases)] {
                var session = InputSession(candidateGeneration: .deferred)
                session.configure(languages: languages)
                session.append(input)
                let request = try #require(session.pendingCandidateRequest)
                for values in [request.generatePreview().candidates, request.generate().candidates] {
                    let first = try #require(values.first { !$0.isPartial })
                    #expect(first.text == "那我们在查询")
                    #expect(!first.isPartial && !first.isMixed && !first.isUserPhrase)
                    #expect(values.last?.text == input && values.last?.isLiteral == true)
                    let prefix = try #require(values.first { $0.text == "那我们" && $0.isPartial })
                    let consumed = try #require(prefix.consumedInputCount)
                    #expect(String(input.dropFirst(consumed)).replacingOccurrences(of: "'", with: "") == "zaichaxun")
                }
            }
        }
    }

}
