import Foundation
import Testing
@testable import SICore

struct SentenceSnapshotTests {
    @Test func captureRequiresABoundedCaretAndNonemptySingleLine() {
        let text = "你好，世界！👩‍💻 "
        let length = text.utf16.count
        #expect(SentenceSnapshot.accepts(text))
        #expect(SentenceSnapshot.range(endingAt: NSRange(location: length, length: 0)) == NSRange(location: 0, length: length))
        #expect(SentenceSnapshot.range(endingAt: NSRange(location: length, length: 1)) == nil)
        #expect(SentenceSnapshot.range(endingAt: NSRange(location: NSNotFound, length: NSNotFound)) == nil)
        #expect(SentenceSnapshot.range(endingAt: NSRange(location: 1_025, length: 0)) == nil)
        for text in ["", " 　", "一\n二", "一\u{2028}二", "一\0二", String(repeating: "🙂", count: 513)] {
            #expect(!SentenceSnapshot.accepts(text))
        }
    }
}
