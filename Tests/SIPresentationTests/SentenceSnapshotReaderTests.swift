import Foundation
import Testing
import SICore
@testable import SIPresentation

struct SentenceSnapshotReaderTests {
    private let noMarkedText = NSRange(location: NSNotFound, length: 0)

    @Test func readsExactUTF16RangeAtEndOfText() {
        let text = "你好，世界！👩‍💻 "
        let caret = NSRange(location: text.utf16.count, length: 0)
        let captured = SentenceSnapshotReader.read(isCurrent: { true }, selection: { caret },
            markedRange: { noMarkedText }, textLength: { caret.location }, textInRange: { range in
                #expect(range == NSRange(location: 0, length: caret.location))
                return text
            })
        #expect(captured?.utf8.elementsEqual(text.utf8) == true)

        for available in ["你好", text + "世界"] {
            #expect(SentenceSnapshotReader.read(isCurrent: { true }, selection: { caret },
                markedRange: { noMarkedText }, textLength: { caret.location }, textInRange: { _ in available }) == nil)
        }
    }

    @Test func skipsInvalidHostRangesBeforeReadingText() {
        let caret = NSRange(location: 2, length: 0)
        for (selection, marked, length) in [
            (NSRange(location: NSNotFound, length: 0), noMarkedText, 2),
            (NSRange(location: 2, length: 1), noMarkedText, 2),
            (NSRange(location: 1_025, length: 0), noMarkedText, 1_025),
            (caret, NSRange(location: 0, length: 2), 2),
            (caret, noMarkedText, 5),
            (caret, noMarkedText, NSNotFound)
        ] {
            #expect(SentenceSnapshotReader.read(isCurrent: { true }, selection: { selection },
                markedRange: { marked }, textLength: { length }, textInRange: { _ in
                    Issue.record("An invalid range must stop the text read.")
                    return "你好"
                }) == nil)
        }
    }

    @Test func revalidatesAfterEveryHostCallback() {
        for invalidatingCall in 1...6 {
            var calls = 0
            var active = true
            var failure: SentenceSnapshot.CaptureFailure?
            func callback() {
                #expect(active)
                calls += 1
                if calls == invalidatingCall { active = false }
            }
            let result = SentenceSnapshotReader.read(isCurrent: { active }, selection: {
                callback()
                return NSRange(location: 2, length: 0)
            }, markedRange: {
                callback()
                return noMarkedText
            }, textLength: {
                callback()
                return 2
            }, textInRange: { _ in
                callback()
                return "你好"
            }, onFailure: { failure = $0 })
            #expect(result == nil)
            #expect(failure == .staleClient)
            #expect(calls == invalidatingCall)
        }
    }
}
