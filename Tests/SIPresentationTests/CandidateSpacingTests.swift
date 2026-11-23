import Foundation
import Testing
import SICore
@testable import SIPresentation

struct CandidateSpacingTests {
    private func commit(_ text: String, language: InputLanguage? = .english,
                        isMixed: Bool = false, isPunctuation: Bool = false,
                        remaining: String = "") -> InputCommit {
        InputCommit(input: "synthetic", candidate: InputCandidate(text: text, language: language, score: 1,
            isMixed: isMixed, punctuationLanguage: isPunctuation ? language : nil, isPunctuation: isPunctuation),
            reason: .explicitSelection, remainingInput: remaining)
    }

    @Test func insertsOnlyAtChineseEnglishBoundariesInEitherDirection() {
        for before in ["中文", "𠀀", "文\u{E0100}", "〇"] {
            #expect(CandidateSpacing(commit: commit("hello"), before: before).prefix == " ")
        }
        for before in ["hello", "HELLO", "e\u{301}"] {
            for text in ["中文", "𠀀", "〇"] {
                #expect(CandidateSpacing(commit: commit(text, language: .simplifiedChinese), before: before).prefix == " ")
            }
        }
    }

    @Test func sameScriptsWhitespacePunctuationNumbersAndFieldStartRemainUnchanged() {
        for before in [nil, "", "中文 ", "中文\u{3000}", "中文\n", "中文\t", "123", "。", "👩‍💻"] {
            #expect(CandidateSpacing(commit: commit("hello"), before: before).prefix.isEmpty)
            #expect(CandidateSpacing(commit: commit("中文", language: .simplifiedChinese), before: before).prefix.isEmpty)
        }
        #expect(CandidateSpacing(commit: commit("world"), before: "hello").prefix.isEmpty)
        #expect(CandidateSpacing(commit: commit("中文", language: .simplifiedChinese), before: "中文").prefix.isEmpty)
        for text in [" hello", "123", ".", "👩‍💻"] {
            #expect(CandidateSpacing(commit: commit(text), before: "文").prefix.isEmpty)
        }
    }

    @Test func mixedLiteralAndPrefixChoicesUseActualOutputBoundaries() {
        #expect(CandidateSpacing(commit: commit("hello 中文", language: .simplifiedChinese, isMixed: true), before: "文").prefix == " ")
        #expect(CandidateSpacing(commit: commit("中文 hello", language: .simplifiedChinese, isMixed: true), before: "hello").prefix == " ")
        #expect(CandidateSpacing(commit: commit("hello", remaining: "world"), before: "文").prefix == " ")
        let literal = InputCommit(input: "MyType", candidate: nil, reason: .literal)
        #expect(CandidateSpacing(commit: literal, before: "文").prefix == " ")
        #expect(literal.text == "MyType")
        for text in [",", "hello,"] {
            #expect(CandidateSpacing(commit: commit(text, isPunctuation: true), before: "文").prefix.isEmpty)
        }
    }
}
