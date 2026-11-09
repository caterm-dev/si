import Foundation
import Testing
import SICore
@testable import SIPresentation

struct SentenceSnapshotReaderTests {
    @Test func savesAvailableTextWithoutRequiringACompleteDocument() {
        let text = "你好，世界！👩‍💻 "
        let caret = NSRange(location: text.utf16.count, length: 0)
        let captured = SentenceSnapshotReader.read(isCurrent: { true }, selection: { caret },
            markedRange: { NSRange(location: NSNotFound, length: 0) }, textInRange: { range in
                #expect(range == NSRange(location: 0, length: caret.location))
                return text
            })
        #expect(captured?.utf8.elementsEqual(text.utf8) == true)
        // Hosts may expose only part of the requested prefix, or extra text. Save
        // their exact available bytes within the independent single-line/size bound.
        for available in ["你好", text + "世界"] {
            let result = SentenceSnapshotReader.read(isCurrent: { true }, selection: { caret },
                markedRange: { NSRange(location: NSNotFound, length: 0) }, textInRange: { _ in available })
            #expect(result?.utf8.elementsEqual(available.utf8) == true)
        }
    }

    @Test func reportsUnavailableCaretAndText() {
        var failure: SentenceSnapshot.CaptureFailure?
        #expect(SentenceSnapshotReader.read(isCurrent: { true },
            selection: { NSRange(location: NSNotFound, length: 0) },
            markedRange: { Issue.record("An unknown caret must stop host queries."); return NSRange() },
            textInRange: { _ in nil }, onFailure: { failure = $0 }) == nil)
        #expect(failure == .unavailableSelection)
        #expect(SentenceSnapshotReader.read(isCurrent: { true }, selection: { NSRange(location: 2, length: 0) },
            markedRange: { NSRange(location: NSNotFound, length: 0) },
            textInRange: { _ in nil }, onFailure: { failure = $0 }) == nil)
        #expect(failure == .unavailableText)
    }

    @Test func retainsSizeSingleLineAndSelectionBounds() {
        for text in ["", "  ", "你好\n世界", "你好\0", String(repeating: "🙂", count: 513)] {
            #expect(SentenceSnapshotReader.read(isCurrent: { true }, selection: { NSRange(location: 2, length: 0) },
                markedRange: { NSRange(location: NSNotFound, length: 0) }, textInRange: { _ in text }) == nil)
        }
        for caret in [NSRange(location: 2, length: 1), NSRange(location: 1_025, length: 0)] {
            #expect(SentenceSnapshotReader.read(isCurrent: { true }, selection: { caret },
                markedRange: { NSRange(location: NSNotFound, length: 0) }, textInRange: { _ in
                    Issue.record("An invalid selection must not authorize reading text.")
                    return "你好"
                }) == nil)
        }
    }

    @Test func revalidatesAfterEveryHostCallback() {
        for invalidatingCall in 1...4 {
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
                return NSRange(location: NSNotFound, length: 0)
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
