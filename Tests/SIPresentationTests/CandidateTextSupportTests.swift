import AppKit
import CoreText
import Testing
import SICore
@testable import SIPresentation

@MainActor
struct CandidateTextSupportTests {
    private let missing = "\u{10FFFF}"

    @Test func systemFallbackKeepsSupportedHanCombiningMarksAndEmoji() {
        var support = CandidateTextSupport()
        for text in ["hello", "你好", "𬭶", "𠮷", "e\u{301}", "é", "👩‍💻", "❤️", "hello 世界"] {
            let supported = support.canDisplay(text)
            #expect(supported, "Expected system fallback for \(text)")
        }
        let missingSupported = support.canDisplay(missing)
        let missingWordSupported = support.canDisplay("你好\(missing)world")
        #expect(!missingSupported && !missingWordSupported)
        // Repeated lookups must give the same answer after the cache is populated.
        let cachedMissingSupported = support.canDisplay(missing)
        let cachedHanSupported = support.canDisplay("你好")
        #expect(!cachedMissingSupported && cachedHanSupported)
    }

    @Test func filtersWholeCandidatesBeforeShortlistingWithoutLosingLiteralOrLanguageIdentity() {
        let chinese = InputCandidate(text: "he", language: .simplifiedChinese, score: 100, lexicalTokenCount: 1)
        let english = InputCandidate(text: "he", language: .english, score: 90, lexicalTokenCount: 1)
        let literal = InputCandidate(text: "original\(missing)", language: nil, score: 0)
        let unsupported = [
            InputCandidate(text: missing, language: .simplifiedChinese, score: 150, lexicalTokenCount: 1),
            InputCandidate(text: "词\(missing)", language: .simplifiedChinese, score: 140, consumedInputCount: 2,
                           lexicalTokenCount: 1),
            InputCandidate(text: "personal\(missing)", language: .english, score: 130, isUserPhrase: true),
            InputCandidate(text: "vocabulary\(missing)", language: .english, score: 120, isApplicationVocabulary: true),
        ]
        var selection = CandidateSelection()
        selection.update(unsupported + [chinese, english, literal])
        #expect(selection.candidates == [chinese, english, literal])
        #expect(selection.selected == chinese)
        #expect(selection.candidate(number: 2) == english)
        #expect(selection.candidates.last?.text.utf8.elementsEqual(literal.text.utf8) == true)
        selection.update([literal])
        #expect(selection.selected == literal)
        selection.update(unsupported)
        #expect(selection.candidates.isEmpty && selection.selected == nil)
    }

    @Test func missingWordsDoNotUseTheOrdinaryCandidateBudget() {
        let unsupported = (0..<30).map {
            InputCandidate(text: "\(missing)\($0)", language: .english, score: 200 - $0, lexicalTokenCount: 1)
        }
        let supported = (0..<30).map {
            InputCandidate(text: "word\($0)", language: .english, score: 100 - $0, lexicalTokenCount: 1)
        }
        let literal = InputCandidate(text: "synthetic", language: nil, score: 0)
        var selection = CandidateSelection()
        selection.update(unsupported + supported + [literal])
        #expect(selection.candidates == Array(supported.prefix(26)) + [literal])
    }

    @Test func reportedSpellingUsesTheSameFilteredListForRenderingNumbersAndMouse() throws {
        for preview in [true, false] {
            var session = InputSession(candidateGeneration: .deferred)
            session.append("heihe")
            let request = try #require(session.pendingCandidateRequest)
            let accepted = session.accept(preview ? request.generatePreview() : request.generate())
            #expect(accepted)
            let engineCandidates = session.candidates
            var selection = CandidateSelection()
            selection.update(engineCandidates)
            #expect(session.candidates == engineCandidates)
            #expect(selection.candidates.contains { $0.text == "黑" && $0.isPartial })
            #expect(selection.candidates.last?.text == "heihe" && selection.candidates.last?.isLiteral == true)
            for candidate in engineCandidates where !candidate.isLiteral {
                // Independent whole-string shaping checks the actual rendered font runs.
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: candidate.text,
                    attributes: [.font: CandidateTextSupport.font]))
                let missingRun = (CTLineGetGlyphRuns(line) as! [CTRun]).contains { run in
                    let font = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
                    return CTFontCopyPostScriptName(font) as String == "LastResort"
                }
                if missingRun { #expect(!selection.candidates.contains { $0.id == candidate.id }) }
            }
            for expanded in [false, true] {
                selection.setExpanded(expanded)
                selection.move(by: -selection.selectedIndex)
                let view = CandidateListView()
                var clicked: String?
                view.onSelect = { clicked = $0 }
                for index in selection.candidates.indices {
                    selection.move(by: index - selection.selectedIndex)
                    let chosen = try #require(selection.selected)
                    let number = index % CandidateSelection.pageSize + 1
                    #expect(selection.candidate(number: number) == chosen)
                    view.render(selection)
                    let row = view.rows[index - selection.displayedRange.lowerBound]
                    #expect(row.candidateLabel.stringValue.utf8.elementsEqual(chosen.text.utf8))
                    #expect(row.numberLabel.stringValue == String(number))
                    row.performClick(nil)
                    #expect(clicked == chosen.id)
                }
            }
            let prefix = try #require(selection.candidates.first { $0.text == "黑" && $0.isPartial })
            let commit = session.commitResult(prefix, reason: .explicitSelection)
            #expect(commit.text == "黑" && commit.input == "hei" && session.buffer == "he")
        }
    }
}
