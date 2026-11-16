import AppKit
import Testing
import SICore
@testable import SIPresentation

struct SentenceSnapshotReaderTests {
    private let noMarkedText = NSRange(location: NSNotFound, length: 0)

    @Test func readsBothSidesOfASelectionAndAcceptsMultilineText() {
        let text = "你好👩‍💻\n" + String(repeating: "学", count: 2_000) + "\nZornax"
        let range = NSRange(location: 0, length: text.utf16.count)
        let snapshot = SentenceSnapshotReader.read(isCurrent: { true },
            selection: { NSRange(location: 2, length: 5) }, markedRange: { noMarkedText },
            textLength: { range.length }, textInRange: {
                #expect($0 == range)
                return text
            }, textWithActualRange: { _ in nil })
        #expect(snapshot?.utf8.elementsEqual(text.utf8) == true)
    }

    @MainActor
    @Test func nativeTextViewReturnsItsFullValueWhenLengthIsUnavailable() {
        let host = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 100))
        // The first proposed range splits the emoji's surrogate pair.
        let text = String(repeating: "学", count: 4_095) + "🙂\nZornax"
        host.string = text
        host.setSelectedRange(NSRange(location: 2, length: 0))
        var requests: [Int] = []
        let snapshot = SentenceSnapshotReader.read(
            isCurrent: { true }, selection: host.selectedRange, markedRange: host.markedRange,
            textLength: { NSNotFound }, textInRange: { _ in nil },
            textWithActualRange: { range in
                requests.append(range.length)
                var actual = NSRange(location: NSNotFound, length: 0)
                guard let returned = host.attributedSubstring(forProposedRange: range, actualRange: &actual) else { return nil }
                return (returned.string, actual)
            }
        )
        #expect(requests.count > 1)
        #expect(snapshot?.utf8.elementsEqual(text.utf8) == true)
    }

    @Test func skipsPartialResponsesAndMarkedText() {
        let caret = NSRange(location: 2, length: 0)
        #expect(SentenceSnapshotReader.read(
            isCurrent: { true }, selection: { caret }, markedRange: { noMarkedText },
            textLength: { 3 }, textInRange: { _ in "你好" }, textWithActualRange: { _ in nil }
        ) == nil)

        #expect(SentenceSnapshotReader.read(
            isCurrent: { true }, selection: { caret }, markedRange: { noMarkedText },
            textLength: { NSNotFound }, textInRange: { _ in nil },
            textWithActualRange: { _ in ("你好", NSRange(location: 1, length: 2)) }
        ) == nil)

        #expect(SentenceSnapshotReader.read(
            isCurrent: { true }, selection: { caret }, markedRange: { NSRange(location: 0, length: 2) },
            textLength: { Issue.record("Reading must stop when the host reports marked text."); return 2 },
            textInRange: { _ in nil }, textWithActualRange: { _ in nil }
        ) == nil)
    }

    @Test func revalidatesAfterEveryHostCallback() {
        for invalidatingCall in 1...7 {
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
                return NSRange(location: 1, length: 0)
            }, markedRange: {
                callback()
                return noMarkedText
            }, textLength: {
                callback()
                return 2
            }, textInRange: { _ in
                callback()
                return "你好"
            }, textWithActualRange: { _ in nil }, onFailure: { failure = $0 })
            #expect(result == nil)
            #expect(failure == .staleClient)
            #expect(calls == invalidatingCall)
        }
    }
}
