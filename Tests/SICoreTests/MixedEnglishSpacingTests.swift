import Foundation
import Testing
@testable import SICore

struct MixedEnglishSpacingTests {
    private let languages = Set(InputLanguage.allCases)

    @Test func reportedEnglishTokensKeepTheirSpacesInPreviewAndFullResults() throws {
        let engine = CandidateEngine()
        let input = "lianxiandan"
        for values in [engine.candidates(for: input, languages: languages),
                       engine.previewCandidates(for: input, languages: languages, learning: LearningProfile(),
                           dictionary: UserDictionary(), now: .now, context: nil)] {
            let prefix = try #require(values.first { $0.text == "联系 and" && $0.consumedInputCount == 9 })
            #expect(prefix.isMixed && !prefix.hasLiteralSegments)
            #expect(values.contains { $0.text == "联系 and an" && !$0.isPartial && $0.isMixed })
            #expect(!values.contains { $0.text == "联系anda" || $0.text == "联系andan" })
            #expect(values.last?.text == input && values.last?.isLiteral == true)
            #expect(Set(values.map(\.id)).count == values.count)
        }
    }

    @Test(arguments: [
        ("nihaohelloworld", "你好 hello world", false),
        ("helloworldzhongwen", "hello world 中文", false),
        ("nihaohelloworldzhongwen", "你好 hello world 中文", false),
        ("hellozhongwenandworld", "hello 中文 and world", false),
        ("nihaoHELLOWORLD", "你好 HELLO WORLD", false),
        ("nihaohelloworl", "你好 hello world", true),
    ])
    func englishRunsKeepSpacesAcrossLanguageBoundaries(input: String, expected: String, completion: Bool) throws {
        let engine = CandidateEngine()
        for values in [engine.candidates(for: input, languages: languages),
                       engine.previewCandidates(for: input, languages: languages, learning: LearningProfile(),
                           dictionary: UserDictionary(), now: .now, context: nil)] {
            let candidate = try #require(values.first { $0.text == expected && !$0.isPartial && $0.isMixed })
            #expect(candidate.hasCompletion == completion)
            #expect(!candidate.hasLiteralSegments && candidate.text.utf8.count <= PinyinDecoder.maximumOutputBytes)
            #expect(values.last?.text == input && values.last?.isLiteral == true)
        }
        #expect(engine.candidates(for: input, languages: languages) == engine.candidates(for: input, languages: languages))
    }

    @Test func spacedMixedChoicesCommitExactTextAndSourceBoundaries() throws {
        var wholeSession = InputSession()
        wholeSession.append("lianxiandan")
        let whole = try #require(wholeSession.candidates.first { $0.text == "联系 and an" && !$0.isPartial })
        let wholeCommit = wholeSession.commitResult(whole, reason: .explicitSelection)
        #expect(wholeCommit.text == "联系 and an" && wholeSession.buffer.isEmpty)

        for (input, prefixText, consumed, remainder) in [
            ("lianxiandan", "联系 and", "lianxiand", "an"),
            ("nihaohelloworldzhongwen", "你好 hello world", "nihaohelloworld", "zhongwen"),
            ("lu:se'hello'world'zhongwen", "绿色 hello world", "lu:se'hello'world'", "zhongwen"),
            ("lüse'hello'world'zhongwen", "绿色 hello world", "lüse'hello'world'", "zhongwen"),
        ] {
            var session = InputSession()
            session.append(input)
            let prefix = try #require(session.candidates.first {
                $0.text == prefixText && $0.consumedInputCount == consumed.count
            })
            let commit = session.commitResult(prefix, reason: .explicitSelection)
            #expect(commit.text == prefixText && commit.input == consumed)
            #expect(commit.remainingInput == remainder && session.buffer == remainder)
            #expect(session.commit() == remainder)
        }
        wholeSession.append("lianxiandan")
        #expect(wholeSession.commit() == "lianxiandan")
    }

    @Test func mixedWholeCandidatesKeepEnglishSpacesWithoutScoringTheirPrefixes() throws {
        let input = "nihaohelloworldzhongwen"
        let values = CandidateEngine().candidates(for: input, languages: languages)
        let full = try #require(values.first { $0.text == "你好 hello world 中文" && !$0.isPartial })
        #expect(full.inputScore == full.rankingScore)
        let prefix = try #require(values.first { $0.text == "你好 hello world" && $0.consumedInputCount == 15 })
        #expect(prefix.inputScore == prefix.rankingScore)
        #expect(prefix.isMixed && prefix.text == "你好 hello world")
    }
}
