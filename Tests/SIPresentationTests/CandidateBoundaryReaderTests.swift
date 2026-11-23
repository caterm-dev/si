import Foundation
import Testing
@testable import SIPresentation

struct CandidateBoundaryReaderTests {
    @Test func readsOutsideTheEntireMarkedRangeRegardlessOfCaretPosition() throws {
        for before in ["", "中文", "👩‍💻𠀀", "文\u{E0100}", "中文 "] {
            let markedText = "hel lo"
            let field = (before + markedText + " 后文") as NSString
            let marked = NSRange(location: before.utf16.count, length: markedText.utf16.count)
            let selection = NSRange(location: marked.location + 2, length: 0)
            var requests: [NSRange] = []
            let boundary = try #require(CandidateBoundaryReader.read(
                markedText: markedText, cursorUTF16Offset: 2, isCurrent: { true },
                selection: { selection }, markedRange: { marked }, text: { range in
                    requests.append(range)
                    return field.substring(with: range)
                }))
            #expect(boundary == String(decoding: Array(before.utf16.suffix(4)), as: UTF16.self))
            #expect(requests.allSatisfy { $0 == marked || $0.length <= 4 })
            #expect(requests.allSatisfy { NSMaxRange($0) <= NSMaxRange(marked) })
        }
    }

    @Test func unavailablePrecedingTextReturnsNoContext() {
        let marked = NSRange(location: 2, length: 5)
        let boundary = CandidateBoundaryReader.read(
            markedText: "hello", cursorUTF16Offset: 5, isCurrent: { true },
            selection: { NSRange(location: 7, length: 0) }, markedRange: { marked },
            text: { $0 == marked ? "hello" : nil })
        #expect(boundary == nil)
    }

    @Test func rejectsInvalidRangesAndInlineText() {
        let valid = NSRange(location: 2, length: 5)
        for marked in [NSRange(location: NSNotFound, length: 0), NSRange(location: 0, length: 0),
                       NSRange(location: -1, length: 5), NSRange(location: Int.max - 2, length: 5)] {
            #expect(CandidateBoundaryReader.read(markedText: "hello", cursorUTF16Offset: 5,
                isCurrent: { true }, selection: { valid }, markedRange: { marked }, text: { _ in
                    Issue.record("Invalid ranges must not read host text.")
                    return nil
                }) == nil)
        }
        #expect(CandidateBoundaryReader.read(markedText: "hello", cursorUTF16Offset: 5,
            isCurrent: { true }, selection: { NSRange(location: 7, length: 0) }, markedRange: { valid },
            text: { _ in "other" }) == nil)
        #expect(CandidateBoundaryReader.read(markedText: "hello", cursorUTF16Offset: 5,
            isCurrent: { true }, selection: { NSRange(location: 3, length: 0) }, markedRange: { valid },
            text: { _ in Issue.record("A stale caret must not read host text."); return nil }) == nil)
    }

    @Test func rejectsReentrantChangesDuringHostReads() {
        let marked = NSRange(location: 2, length: 5)
        for invalidatesCurrent in [true, false] {
            var current = true
            var caret = NSRange(location: 7, length: 0)
            #expect(CandidateBoundaryReader.read(markedText: "hello", cursorUTF16Offset: 5,
                isCurrent: { current }, selection: { caret }, markedRange: { marked }, text: { range in
                    if range == marked { return "hello" }
                    if invalidatesCurrent { current = false } else { caret.location = 0 }
                    return "中文"
                }) == nil)
        }
    }
}
