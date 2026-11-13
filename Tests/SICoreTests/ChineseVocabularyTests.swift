import Foundation
import Testing
@testable import SICore

struct ChineseVocabularyTests {
    @Test func reviewedCorpusTermsRemainSelectableWithExactLiteralAndLanguageFiltering() throws {
        let engine = CandidateEngine()
        let cases = [("chunyou", "唇釉"), ("kongliebiao", "空列表"),
                     ("kechixufazhan", "可持续发展"), ("guojiafazhangaigewei", "国家发展改革委")]
        for (input, text) in cases {
            for languages: Set<InputLanguage> in [[.simplifiedChinese], Set(InputLanguage.allCases)] {
                let values = engine.candidates(for: input, languages: languages)
                let candidate = try #require(values.first { $0.text == text && !$0.isPartial })
                #expect(candidate.language == .simplifiedChinese && !candidate.isMixed)
                #expect(values.last?.isLiteral == true && values.last?.text == input)
                var session = InputSession()
                session.append(input)
                let selected = try #require(session.candidates.first { $0.id == candidate.id })
                let commit = session.commitResult(selected, reason: .explicitSelection)
                #expect(commit.text == text && commit.input == input && session.buffer.isEmpty)
            }
            #expect(!engine.candidates(for: input, languages: [.english]).contains { $0.text == text })
            let literal = engine.candidates(for: input, languages: [])
            #expect(literal.count == 1 && literal.first?.isLiteral == true && literal.first?.text == input)
        }
    }

    @Test func requestedAlchemyPhraseIsACompleteDictionaryCandidate() throws {
        let engine = CandidateEngine()
        for input in ["lianxiandan", "lian'xian'dan"] {
            for languages: Set<InputLanguage> in [[.simplifiedChinese], Set(InputLanguage.allCases)] {
                for values in [engine.candidates(for: input, languages: languages),
                               engine.previewCandidates(for: input, languages: languages, learning: LearningProfile(),
                                   dictionary: UserDictionary(), now: .now, context: nil)] {
                    let phrase = try #require(values.first { $0.text == "炼仙丹" && !$0.isPartial })
                    #expect(phrase.language == .simplifiedChinese && !phrase.isMixed && !phrase.hasCompletion)
                    #expect(phrase.lexicalTokenCount == 1 && !phrase.isUserPhrase && !phrase.hasLiteralSegments)
                    #expect(values.last?.text == input && values.last?.isLiteral == true)
                }
            }
            var session = InputSession()
            session.append(input)
            let phrase = try #require(session.candidates.first { $0.text == "炼仙丹" && !$0.isPartial })
            let commit = session.commitResult(phrase, reason: .explicitSelection)
            #expect(commit.text == "炼仙丹" && commit.input == input && session.buffer.isEmpty)
            #expect(!engine.candidates(for: input, languages: [.english]).contains { $0.text == "炼仙丹" })
        }
    }

    @Test func sentenceFinalMaKeepsChineseAndEnglishAlternatives() throws {
        let engine = CandidateEngine()
        let input = "nengxiangbanfayouhuama"
        for languages: Set<InputLanguage> in [[.simplifiedChinese], Set(InputLanguage.allCases)] {
            let values = engine.candidates(for: input, languages: languages)
            let first = try #require(values.first { !$0.isPartial })
            #expect(first.text.hasSuffix("吗"))
            #expect(values.filter { !$0.isPartial }.prefix(3).contains { $0.text == "能想办法优化吗" })
            #expect(!first.isPartial && !first.isMixed && !first.hasCompletion && !first.hasLiteralSegments)
            #expect(values.last?.text == input && values.last?.isLiteral == true)
            #expect(values == engine.candidates(for: input, languages: languages))
            if languages.contains(.english) {
                #expect(values.contains { $0.text == "能想办法优化 may" && $0.isMixed && !$0.isPartial && $0.hasCompletion })
            }
        }

        // A saved English token choice may reorder results, but must keep the Chinese ending available.
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let profile = LearningProfile(entries: [
            LearnedPreference(input: "ma", text: "may", language: .english, strength: 8, lastUsed: now),
        ], now: now)
        let personalized = engine.candidates(for: input, languages: Set(InputLanguage.allCases),
                                             learning: profile, now: now)
        #expect(personalized.contains { $0.text == "能想办法优化吗" && !$0.isPartial })
        #expect(personalized.contains { $0.text == "能想办法优化 may" && $0.isMixed && !$0.isPartial && $0.hasCompletion })
        #expect(personalized.last?.text == input && personalized.last?.isLiteral == true)
    }

    @Test func importedWordsCharactersAndReadingsJoinTheExistingEngine() {
        let engine = CandidateEngine()
        for (input, expected) in [("zimu", "字幕"), ("shujuku", "数据库"), ("zhuban", "主板"),
                                  ("rengongzhineng", "人工智能"), ("cikuweihu", "词库维护")] {
            let values = engine.candidates(for: input, languages: [.simplifiedChinese])
            #expect(values.contains { $0.text == expected && !$0.isPartial })
            #expect(values.last?.text == input && values.last?.isLiteral == true)
            #expect(values == engine.candidates(for: input, languages: [.simplifiedChinese]))
            #expect(!engine.candidates(for: input, languages: [.english]).contains { $0.text == expected })
        }
        #expect(engine.candidates(for: "zimusubtitle", languages: Set(InputLanguage.allCases))
            .contains { $0.text == "字幕 subtitle" && $0.isMixed && !$0.hasLiteralSegments })
        #expect(engine.candidates(for: "xing", languages: [.simplifiedChinese]).contains { $0.text == "行" })
        #expect(engine.candidates(for: "hang", languages: [.simplifiedChinese]).contains { $0.text == "行" })
    }

}
