import Testing
@testable import SICore

struct PinyinPreviewQualityTests {
    @Test func writingRequestRetainsItsWholeCandidateAcrossSearchStages() throws {
        for languages: Set<InputLanguage> in [[.simplifiedChinese], Set(InputLanguage.allCases)] {
            var session = InputSession(candidateGeneration: .deferred)
            session.configure(languages: languages)
            for (suffix, expected) in [("bangwozaixie", "帮我再写"), ("yige", "帮我再写一个")] {
                for letter in suffix { session.append(String(letter)) }
                let request = try #require(session.pendingCandidateRequest)
                let preview = request.generatePreview()
                let final = request.generate()
                for result in [preview, final] {
                    let candidate = try #require(result.candidates.prefix(4).first { $0.text == expected })
                    #expect(!candidate.isPartial && !candidate.hasCompletion)
                    #expect(result.candidates.last?.text == session.buffer)
                    #expect(result.candidates.last?.isLiteral == true)
                }
                #expect(session.accept(preview) == true)
                #expect(session.accept(final) == true)
                #expect(session.candidates.prefix(4).contains { $0.text == expected })
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
                #expect(result.candidates.prefix(2).contains {
                    $0.text == "你说的这个" && !$0.isPartial && !$0.hasCompletion && !$0.isMixed
                })
                #expect(!result.candidates.prefix(2).contains { $0.text == "你书哦的这个" })
                #expect(result.candidates.last?.text == "nishuodezhege")
                #expect(result.candidates.last?.isLiteral == true)
            }
        }
    }

    @Test func previewScoresHomophonesBeforeBoundingTheirFanout() {
        let homophones = (0..<24).map {
            PinyinLexiconEntry(syllables: ["shuo"], text: String(UnicodeScalar(0x4E00 + $0)!), score: 50)
        }
        let speech = PinyinLexiconEntry(syllables: ["shuo"], text: "说")
        let surrounding = [
            PinyinLexiconEntry(syllables: ["ni"], text: "你"),
            PinyinLexiconEntry(syllables: ["shu"], text: "书"),
            PinyinLexiconEntry(syllables: ["o"], text: "哦"),
            PinyinLexiconEntry(syllables: ["de"], text: "的"),
            PinyinLexiconEntry(syllables: ["zhe", "ge"], text: "这个"),
        ]
        for entries in [homophones + [speech], [speech] + homophones] {
            let decoder = PinyinDecoder(entries: surrounding + entries)
            let final = decoder.compositionCandidates(for: "nishuodezhege", languages: [.simplifiedChinese])
            let preview = decoder.compositionCandidates(for: "nishuodezhege", languages: [.simplifiedChinese],
                                                        preview: true)
            #expect(final.first?.text == "你说的这个")
            #expect(preview.first?.text == "你说的这个")
        }
    }
}
