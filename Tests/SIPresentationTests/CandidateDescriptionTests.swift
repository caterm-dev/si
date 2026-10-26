import Foundation
import Testing
import SICore
import SILocalization
@testable import SIPresentation

struct CandidateDescriptionTests {
    @Test func englishLabelsRetainTheirExistingMeaning() throws {
        let bundle = try localizedBundle("en")
        let candidates = [
            InputCandidate(text: "Hello", language: .english, score: 10),
            InputCandidate(text: "你好", language: .simplifiedChinese, score: 10, consumedInputCount: 5),
            InputCandidate(text: "我deploy", language: .english, score: 10, isMixed: true),
            InputCandidate(text: "我identifier", language: .simplifiedChinese, score: 10, isMixed: true, hasLiteralSegments: true),
            InputCandidate(text: "Synthetic", language: .english, score: 10, isUserPhrase: true),
            InputCandidate(text: "Synthetic", language: .english, score: 10, isApplicationVocabulary: true),
            InputCandidate(text: "Synthetic", language: .english, score: 10, isHistory: true),
            InputCandidate(text: "，", language: .simplifiedChinese, score: 10, punctuationLanguage: .simplifiedChinese),
            InputCandidate(text: ",", language: .english, score: 10, punctuationLanguage: .english),
            InputCandidate(text: "Exact e\u{301}", language: nil, score: 0),
        ]
        for candidate in candidates {
            #expect(CandidateDescription.label(for: candidate, bundle: bundle) == candidate.label)
        }
    }

    @Test func chineseLabelsDoNotChangeIdentityOrCommittedBytes() throws {
        let bundle = try localizedBundle("zh-Hans")
        let prefix = InputCandidate(text: "你好", language: .simplifiedChinese, score: 10, consumedInputCount: 5)
        #expect(CandidateDescription.label(for: prefix, bundle: bundle) == "前 5 个字符 · 中文（简体）")
        let candidate = InputCandidate(text: "Hello e\u{301}", language: .english, score: 10, isUserPhrase: true)
        let original = candidate
        #expect(CandidateDescription.label(for: candidate, bundle: bundle) == "个人短语 · 英文")
        #expect(candidate.id == original.id && candidate.text.utf8.elementsEqual(original.text.utf8))
        var session = InputSession()
        session.configure(languages: [])
        session.append(candidate.text)
        let literal = try #require(session.candidates.first)
        #expect(CandidateDescription.label(for: literal, bundle: bundle) == "原样输入")
        #expect(session.commitResult(literal, reason: .explicitSelection).text.utf8.elementsEqual(original.text.utf8))
    }

    private func localizedBundle(_ language: String) throws -> Bundle {
        let path = try #require(L10n.bundle.path(forResource: language, ofType: "lproj"))
        return try #require(Bundle(path: path))
    }
}
