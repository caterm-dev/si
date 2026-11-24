import Foundation
import Testing
@testable import SIPresentation

struct PrecedingTextReaderTests {
    private let noMark = NSRange(location: NSNotFound, length: 0)

    @Test func confirmsFieldStartWithoutRequestingHostText() {
        for selection in [NSRange(location: 0, length: 0), NSRange(location: 0, length: 3)] {
            let result = PrecedingTextReader.read(isCurrent: { true }, selection: { selection }, markedRange: { noMark }) { _ in
                Issue.record("An empty committed prefix does not need a host text read.")
                return nil
            }
            #expect(result == "")
        }
        var reads = 0
        #expect(PrecedingTextReader.read(isCurrent: { true }, selection: {
            reads += 1
            return NSRange(location: reads == 1 ? 0 : 1, length: 0)
        }, markedRange: { noMark }) { _ in nil } == nil)
        #expect(PrecedingTextReader.read(isCurrent: { false }, selection: { NSRange(location: 0, length: 0) },
                                       markedRange: { noMark }) { _ in nil } == nil)
    }

    @Test func readsTheEntirePrefixInUTF16ExcludingTheSelection() {
        let prefix = String(repeating: "第一句。👩‍💻\n", count: 256) + "最后一句。"
        let selection = NSRange(location: prefix.utf16.count, length: 2)
        let result = PrecedingTextReader.read(isCurrent: { true }, selection: { selection }, markedRange: { noMark }) { range in
            #expect(range == NSRange(location: 0, length: prefix.utf16.count))
            return prefix
        }
        #expect(result?.utf8.elementsEqual(prefix.utf8) == true)
    }

    @Test func skipsUnavailableAndStaleContexts() {
        let caret = NSRange(location: 2, length: 0)
        for (selection, mark) in [(noMark, noMark), (caret, NSRange(location: 1, length: 1))] {
            #expect(PrecedingTextReader.read(isCurrent: { true }, selection: { selection }, markedRange: { mark }) { _ in
                Issue.record("Unsupported ranges must not read host text.")
                return "你好"
            } == nil)
        }
        #expect(PrecedingTextReader.read(isCurrent: { true }, selection: { caret }, markedRange: { noMark }) { _ in "你" } == nil)
        var current = true
        #expect(PrecedingTextReader.read(isCurrent: { current }, selection: { caret }, markedRange: { noMark }) { _ in
            current = false
            return "你好"
        } == nil)
        var selection = caret
        #expect(PrecedingTextReader.read(isCurrent: { true }, selection: { selection }, markedRange: { noMark }) { _ in
            selection.location = 0
            return "你好"
        } == nil)
    }
}
