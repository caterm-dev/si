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
        #expect(snapshot?.text.utf8.elementsEqual(text.utf8) == true)
        #expect(snapshot?.coverage == .fullField)
    }

    @MainActor
    @Test(arguments: [NSNotFound, 0])
    func nativeTextViewReturnsItsFullValueWhenLengthIsUnavailable(reportedLength: Int) {
        let host = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 100))
        // The first proposed range splits the emoji's surrogate pair.
        let text = String(repeating: "学", count: 4_095) + "🙂\nZornax"
        host.string = text
        host.setSelectedRange(NSRange(location: 2, length: 0))
        var requests: [Int] = []
        let snapshot = SentenceSnapshotReader.read(
            isCurrent: { true }, selection: host.selectedRange, markedRange: host.markedRange,
            textLength: { reportedLength }, textInRange: { _ in nil },
            textWithActualRange: { range in
                requests.append(range.length)
                var actual = NSRange(location: NSNotFound, length: 0)
                guard let returned = host.attributedSubstring(forProposedRange: range, actualRange: &actual) else { return nil }
                return (returned.string, actual)
            }
        )
        #expect(requests.count > 1)
        #expect(snapshot?.text.utf8.elementsEqual(text.utf8) == true)
        #expect(snapshot?.coverage == .fullField)
    }

    @Test(arguments: [0, NSNotFound, 10_000])
    func usesTheLegacyPrefixReadWhenTheHostCannotSupplyTheFullField(reportedLength: Int) {
        let prefix = String(repeating: "学", count: 2_000) + "🙂\nZornax"
        let caret = NSRange(location: prefix.utf16.count, length: 0)
        let snapshot = SentenceSnapshotReader.read(
            isCurrent: { true }, selection: { caret }, markedRange: { noMarkedText },
            textLength: { reportedLength }, textInRange: { range in
                range.location == 0 && range.length == caret.location ? prefix : nil
            }, textWithActualRange: { _ in nil }
        )
        #expect(snapshot?.coverage == .beforeCaret)
        #expect(snapshot?.text.utf8.elementsEqual(prefix.utf8) == true)
    }

    @Test func doesNotReadThePrefixAfterTheFullReadInvalidatesTheClient() {
        var active = true
        var failure: SentenceSnapshot.CaptureFailure?
        let snapshot = SentenceSnapshotReader.read(
            isCurrent: { active }, selection: { NSRange(location: 2, length: 0) }, markedRange: { noMarkedText },
            textLength: { 0 }, textInRange: { _ in
                Issue.record("A stale client must not be queried again.")
                return "你好"
            }, textWithActualRange: { _ in
                active = false
                return nil
            }, onFailure: { failure = $0 }
        )
        #expect(snapshot == nil)
        #expect(failure == .staleClient)
    }

    @Test func distinguishesAnEmptyFieldFromTextTheHostDidNotProvide() {
        for (selection, response, expected) in [
            (NSRange(location: 0, length: 0), ("", NSRange(location: 0, length: 0)), SentenceSnapshot.CaptureFailure.invalidText),
            (NSRange(location: 1, length: 0), ("", NSRange(location: 0, length: 0)), .incompleteRange),
            (NSRange(location: 1, length: 0), nil, .unavailableText)
        ] {
            var failure: SentenceSnapshot.CaptureFailure?
            let snapshot = SentenceSnapshotReader.read(isCurrent: { true },
                selection: { selection }, markedRange: { noMarkedText }, textLength: { 0 },
                textInRange: { _ in response?.0 }, textWithActualRange: { _ in response }, onFailure: { failure = $0 })
            #expect(snapshot == nil)
            #expect(failure == expected)
        }
    }

    @Test func skipsPartialResponsesAndMarkedText() {
        let caret = NSRange(location: 2, length: 0)
        #expect(SentenceSnapshotReader.read(
            isCurrent: { true }, selection: { caret }, markedRange: { noMarkedText },
            textLength: { 3 }, textInRange: { _ in "你" }, textWithActualRange: { _ in nil }
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
