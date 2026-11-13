import Testing
@testable import SICore

struct PinyinPreviewQualityTests {
    @Test func writingRequestCanCommitTheFinalCandidateAfterPreview() throws {
        for languages: Set<InputLanguage> in [[.simplifiedChinese], Set(InputLanguage.allCases)] {
            var session = InputSession(candidateGeneration: .deferred)
            session.configure(languages: languages)
            for (suffix, expected) in [("bangwozaixie", "帮我再写"), ("yige", "帮我再写一个")] {
                for letter in suffix { session.append(String(letter)) }
                let request = try #require(session.pendingCandidateRequest)
                let preview = request.generatePreview()
                let final = request.generate()
                for result in [preview, final] {
                    #expect(result.candidates.contains { !$0.isPartial && !$0.isLiteral })
                    #expect(result.candidates.last?.text == session.buffer)
                    #expect(result.candidates.last?.isLiteral == true)
                }
                #expect(final.candidates.contains { $0.text == expected && !$0.isPartial && !$0.hasCompletion })
                #expect(session.accept(preview) == true)
                #expect(session.accept(final) == true)
                #expect(session.candidates.contains { $0.text == expected && !$0.isPartial })
            }
            let selected = try #require(session.candidates.first { $0.text == "帮我再写一个" })
            let commit = session.commitResult(selected, reason: .explicitSelection)
            #expect(commit.text == "帮我再写一个" && commit.input == "bangwozaixieyige")
            #expect(session.buffer.isEmpty)
        }
    }

    @Test func everydaySpeechRemainsAvailableInPreviewAndFinalSearch() throws {
        for languages: Set<InputLanguage> in [[.simplifiedChinese], Set(InputLanguage.allCases)] {
            var session = InputSession(candidateGeneration: .deferred)
            session.configure(languages: languages)
            session.append("nishuodezhege")
            let request = try #require(session.pendingCandidateRequest)
            for result in [request.generatePreview(), request.generate()] {
                #expect(result.candidates.filter { !$0.isPartial }.prefix(2).contains {
                    $0.text == "你说的这个" && !$0.isPartial && !$0.hasCompletion && !$0.isMixed
                })
                #expect(!result.candidates.filter { !$0.isPartial }.prefix(2).contains { $0.text == "你书哦的这个" })
                #expect(result.candidates.last?.text == "nishuodezhege")
                #expect(result.candidates.last?.isLiteral == true)
            }
        }
    }

}
