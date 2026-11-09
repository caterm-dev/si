import Foundation
import Testing
@testable import SIPresentation
@testable import SICore

struct KenLMContextReaderTests {
    @Test func excludesEntireMarkedRangeEvenWhenCaretEditsItsMiddle() throws {
        let before = "👩‍💻我 今天 "
        let markedText = "ni hao"
        let marked = NSRange(location: before.utf16.count, length: markedText.utf16.count)
        let caret = NSRange(location: marked.location + 2, length: 0)
        let document = before + markedText + "后面的内容"
        var reads: [NSRange] = []
        let context = try #require(KenLMContextReader.read(markedText: markedText, isCurrent: { true },
            selection: { caret }, markedRange: { marked }) { range in
                reads.append(range)
                return (document as NSString).substring(with: range)
            })
        #expect(reads == [marked, NSRange(location: 0, length: before.utf16.count)])
        #expect(context.tokens == ["我", "今天"])
    }

    @Test func boundedReadSupportsUnmarkedInsertionInMiddleOfDocument() throws {
        let caret = NSRange(location: 700, length: 0)
        let context = try #require(KenLMContextReader.read(markedText: nil, isCurrent: { true },
            selection: { caret }, markedRange: { NSRange(location: NSNotFound, length: 0) }) { range in
                #expect(range == NSRange(location: 444, length: 256))
                return String(repeating: "我 ", count: 128)
            })
        #expect(context.tokens == ["我", "我", "我"])
    }

    @Test func rejectsUnsafeStaleIncompleteAndUnrelatedHostResponses() {
        let caret = NSRange(location: 8, length: 0)
        let unmarked = NSRange(location: NSNotFound, length: 0)
        var current = true
        #expect(KenLMContextReader.read(markedText: nil, isCurrent: { current }, selection: { caret },
            markedRange: { current = false; return unmarked }, text: { _ in
                Issue.record("Stale host text must not be queried")
                return nil
            }) == nil)
        #expect(KenLMContextReader.read(markedText: nil, isCurrent: { true }, selection: { caret },
            markedRange: { unmarked }, text: { _ in "短" }) == nil)
        #expect(KenLMContextReader.read(markedText: "ni", isCurrent: { true }, selection: { caret },
            markedRange: { NSRange(location: 7, length: 2) }, text: { _ in "xx" }) == nil)
        var selections = 0
        #expect(KenLMContextReader.read(markedText: nil, isCurrent: { true }, selection: {
            selections += 1
            return NSRange(location: selections == 1 ? 8 : 9, length: 0)
        }, markedRange: { unmarked }, text: { _ in "一二三四五六七八" }) == nil)
        #expect(KenLMContextReader.read(markedText: nil, isCurrent: { false }, selection: {
            Issue.record("Secure/direct/inactive clients must not be queried")
            return caret
        }, markedRange: { unmarked }, text: { _ in nil }) == nil)
    }
}
