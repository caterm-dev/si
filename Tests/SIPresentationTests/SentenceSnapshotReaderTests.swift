import Foundation
import Testing
@testable import SIPresentation

struct SentenceSnapshotReaderTests {
    @Test func readsExactlyOneCompleteClientRange() {
        let text = "你好，世界！👩‍💻"
        let length = text.utf16.count
        let caret = NSRange(location: length, length: 0)
        let unmarked = NSRange(location: NSNotFound, length: 0)
        let captured = SentenceSnapshotReader.read(isCurrent: { true }, selection: { caret },
                                                   markedRange: { unmarked }, length: { length }) { range in
            #expect(range == NSRange(location: 0, length: length))
            return text
        }
        #expect(captured?.utf8.elementsEqual(text.utf8) == true)
        #expect(SentenceSnapshotReader.read(isCurrent: { true }, selection: { caret }, markedRange: { unmarked },
                                            length: { length }, textInRange: { _ in "你好" }) == nil)
        #expect(SentenceSnapshotReader.read(isCurrent: { true }, selection: { caret }, markedRange: { unmarked },
                                            length: { length + 1 }, textInRange: { _ in
            Issue.record("The host must not be read when the caret is inside the text.")
            return text
        }) == nil)
    }

    @Test func hostCallbackCanInvalidateCaptureBeforeAnyTextRead() {
        var active = true
        let captured = SentenceSnapshotReader.read(isCurrent: { active }, selection: { NSRange(location: 2, length: 0) },
                                                   markedRange: { NSRange(location: NSNotFound, length: 0) },
                                                   length: {
            active = false
            return 2
        }) { _ in
            Issue.record("A stale client must not be queried.")
            return "你好"
        }
        #expect(captured == nil)
    }
}
