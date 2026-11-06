import Foundation
import Testing
@testable import SICore
@testable import SIPresentation

struct MarkedTextPresentationTests {
    @Test func leadingWholeHypothesisSuppliesSegmentationDespiteHigherRankedPrefixes() {
        let engine = CandidateEngine()
        for (input, expected, languages) in [
            ("chileme", "chi le me", Set(InputLanguage.allCases)),
            ("iwanttobuild", "i want to build", Set([InputLanguage.english])),
        ] {
            let candidates = engine.candidates(for: input, languages: languages)
            let prefix = InputCandidate(text: "synthetic", language: .english, score: 100,
                                        consumedInputCount: 1)
            let display = MarkedTextPresentation(buffer: input, cursor: input.count, candidates: [prefix] + candidates)
            #expect(display.text == expected)
        }
    }

    @Test func chineseSyllablesAndEnglishWordsFollowDecoderSourceCuts() throws {
        let engine = CandidateEngine()
        for (input, output, expected, languages) in [
            ("chileme", "吃了么", "chi le me", Set([InputLanguage.simplifiedChinese])),
            ("NiHao", "你好", "Ni Hao", [.simplifiedChinese]),
            ("iwanttobuild", "I want to build", "i want to build", [.english]),
            ("helloworldzhongwen", "hello world 中文", "hello world zhong wen", Set(InputLanguage.allCases)),
        ] {
            let candidates = engine.candidates(for: input, languages: languages)
            let candidate = try #require(candidates.first { $0.text == output && !$0.isPartial })
            let display = MarkedTextPresentation(buffer: input, cursor: input.count, candidates: [candidate])
            #expect(display.text == expected)
            #expect(display.cursorUTF16Offset == expected.utf16.count)
            #expect(candidates.last?.text == input)
        }
    }

    @Test func sourceOnlySyllableCutsDoNotRequireOneHanCharacterPerSyllable() throws {
        let decoder = PinyinDecoder(entries: [PinyinLexiconEntry(syllables: ["xi", "an"], text: "𰻞")])
        let candidate = try #require(decoder.candidates(for: "xian").first { $0.text == "𰻞" })
        #expect(candidate.confirmationBoundaries.isEmpty)
        #expect(MarkedTextPresentation(buffer: "xian", cursor: 4, candidates: [candidate]).text == "xi an")
    }

    @Test func incompleteChineseSyllablesUseTypedCutsWithoutInventingConfirmationEvidence() throws {
        let decoder = PinyinDecoder(entries: [PinyinLexiconEntry(syllables: ["ni", "hao"], text: "你好")])
        let candidate = try #require(decoder.candidates(for: "niha").first { $0.text == "你好" })
        #expect(candidate.confirmationBoundaries.isEmpty)
        #expect(candidate.sourceTrace == nil)
        #expect(MarkedTextPresentation(buffer: "niha", cursor: 4, candidates: [candidate]).text == "ni ha")
    }

    @Test func aliasesExplicitSeparatorsAndCaretUseExactOriginalSpelling() throws {
        let decoder = PinyinDecoder(entries: [PinyinLexiconEntry(syllables: ["lv", "hao"], text: "吕好")])
        for (input, expected, boundary) in [("lu:hao", "lu: hao", 3), ("LÜHao", "LÜ Hao", 2),
                                           ("lü'hao'", "lü'hao'", 3)] {
            let candidate = try #require(decoder.candidates(for: input).first { $0.text == "吕好" })
            let display = MarkedTextPresentation(buffer: input, cursor: boundary, candidates: [candidate])
            #expect(display.text == expected)
            #expect(display.cursorUTF16Offset == boundary + (input.contains("'") ? 0 : 1))
        }
    }

    @Test func presentationSpacesNeverChangeEditingPrefixOrLiteralCommits() throws {
        var session = InputSession()
        session.configure(languages: [.simplifiedChinese])
        session.append("nihaopengyou")
        let display = MarkedTextPresentation(buffer: session.buffer, cursor: session.cursor, candidates: session.candidates)
        #expect(display.text == "ni hao peng you")
        session.moveCursor(by: -3)
        let middle = MarkedTextPresentation(buffer: session.buffer, cursor: session.cursor, candidates: session.candidates)
        #expect(middle.cursorUTF16Offset == session.cursorUTF16Offset + 3)
        session.deleteBackward()
        #expect(session.buffer == "nihaopenyou")

        session.reset()
        session.append("nihaopengyou")
        let prefix = try #require(session.candidates.first { $0.text == "你好" && $0.isPartial })
        let commit = session.commit(prefix)
        #expect(commit == "你好")
        #expect(session.buffer == "pengyou")
        #expect(MarkedTextPresentation(buffer: session.buffer, cursor: session.cursor,
                                       candidates: session.candidates).text == "peng you")
        let literal = session.commit()
        #expect(literal == "pengyou")
    }

    @Test func unknownDisabledAndUnicodeInputStayByteExact() {
        for input in ["Keep_Bytes", "e\u{301}👩‍💻", "", "ni'hao"] {
            let display = MarkedTextPresentation(buffer: input, cursor: input.count,
                candidates: CandidateEngine().candidates(for: input, languages: []))
            #expect(Array(display.text.utf8) == Array(input.utf8))
            #expect(display.cursorUTF16Offset == input.utf16.count)
        }
        let input = "e\u{301}👩‍💻z"
        let display = MarkedTextPresentation(buffer: input, cursor: 2, candidates: [])
        #expect(display.cursorUTF16Offset == "e\u{301}👩‍💻".utf16.count)
    }

    @Test func pendingAndStaleResultsCannotReuseOldSegmentation() throws {
        var session = InputSession(candidateGeneration: .deferred)
        session.configure(languages: [.simplifiedChinese])
        session.append("nihao")
        let old = try #require(session.pendingCandidateRequest)
        let accepted = session.accept(old.generate())
        #expect(accepted)
        var state = MarkedTextState()
        let segmented = MarkedTextPresentation(buffer: session.buffer, cursor: session.cursor, candidates: session.candidates)
        #expect(segmented.text == "ni hao")
        let sent = state.shouldSend(segmented.text, selection: NSRange(location: segmented.cursorUTF16Offset, length: 0))
        let repeated = state.shouldSend(segmented.text, selection: NSRange(location: segmented.cursorUTF16Offset, length: 0))
        #expect(sent && !repeated)
        session.append("x")
        let staleAccepted = session.accept(old.generate())
        #expect(!staleAccepted)
        let pending = MarkedTextPresentation(buffer: session.buffer, cursor: session.cursor, candidates: session.candidates)
        #expect(pending.text == "nihaox")
        session.reset()
        let cancelledAccepted = session.accept(old.generate())
        #expect(!cancelledAccepted)
        #expect(MarkedTextPresentation(buffer: session.buffer, cursor: session.cursor, candidates: session.candidates).text.isEmpty)
    }
}
