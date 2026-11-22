import AppKit
import Testing
@testable import SIPresentation

struct ReturnFieldLearningTests {
    @Test func acceptsOnlyTheTwoReturnShortcuts() {
        #expect(ReturnFieldLearning.matches(keyCode: 36, modifiers: [], isRepeat: false))
        #expect(ReturnFieldLearning.matches(keyCode: 36, modifiers: .command, isRepeat: false))
        #expect(ReturnFieldLearning.matches(keyCode: 76, modifiers: [.command, .numericPad], isRepeat: false))
        #expect(!ReturnFieldLearning.matches(keyCode: 36, modifiers: .shift, isRepeat: false))
        #expect(!ReturnFieldLearning.matches(keyCode: 36, modifiers: [.command, .option], isRepeat: false))
        #expect(!ReturnFieldLearning.matches(keyCode: 36, modifiers: .command, isRepeat: true))
        #expect(!ReturnFieldLearning.matches(keyCode: 49, modifiers: [], isRepeat: false))
    }

    @Test func onlyFullLiteralContainmentSuppressesIngestion() {
        let sentence = "我明天上午十一点到公司开会"
        #expect(!ReturnFieldLearning.shouldIngest(before: sentence, after: sentence))
        #expect(!ReturnFieldLearning.shouldIngest(before: sentence, after: sentence + "\n"))
        #expect(!ReturnFieldLearning.shouldIngest(before: sentence, after: "\n" + sentence + "\n"))
        #expect(ReturnFieldLearning.shouldIngest(before: sentence, after: "我明天\n上午十一点到公司开会"))
        #expect(ReturnFieldLearning.shouldIngest(before: sentence, after: "另一条草稿"))
        #expect(ReturnFieldLearning.shouldIngest(before: sentence, after: ""))
        #expect(ReturnFieldLearning.shouldIngest(before: sentence, after: nil))
        #expect(ReturnFieldLearning.shouldIngest(before: "é", after: "e\u{0301}"))
        #expect(!ReturnFieldLearning.shouldIngest(before: "", after: nil))
    }

    @Test func readsTheFixedUTF16RangeWithoutASecondClientCheck() {
        let field = "前面🙂后面"
        let unmarked = NSRange(location: NSNotFound, length: NSNotFound)
        var current = true
        var queriedCaret = false
        func read(text: (NSRange) -> String?) -> String? {
            ReturnFieldLearning.read(isCurrent: { current }, selection: {
                queriedCaret = true
                return unmarked
            }, markedRange: { unmarked }, text: text, textWithActualRange: { _ in nil })
        }
        let captured = read { range in
            #expect(range == NSRange(location: 0, length: 1_024))
            current = false
            return field
        }
        #expect(captured == field)
        #expect(!queriedCaret)
        current = true
        #expect(read { _ in String(repeating: "a", count: 1_025) } == nil)
        current = false
        let unread = read { _ in
            Issue.record("Text should only be requested from the active client")
            return field
        }
        #expect(unread == nil)
    }

    @MainActor
    @Test func readsBothSidesOfTheCaretWithAFixedNativeRange() {
        let view = NSTextView(frame: .zero)
        view.string = "我来就错了🙂"
        view.setSelectedRange(NSRange(location: 2, length: 0))
        let before = ReturnFieldLearning.read(isCurrent: { true }, selection: { view.selectedRange() },
                                             markedRange: { view.markedRange() },
                                             text: { _ in nil }, textWithActualRange: { requested in
            #expect(requested == NSRange(location: 0, length: 1_024))
            var actual = NSRange(location: NSNotFound, length: 0)
            guard let text = view.attributedSubstring(forProposedRange: requested, actualRange: &actual) else {
                return nil
            }
            return (text.string, actual)
        })
        #expect(before == view.string)
    }

    @Test func clampedFieldReadRejectsNonzeroOffsetsAndInvalidLengths() {
        let unmarked = NSRange(location: NSNotFound, length: 0)
        func read(at location: Int, reportedLength: Int = 2) -> String? {
            ReturnFieldLearning.read(isCurrent: { true }, selection: { unmarked }, markedRange: { unmarked },
                                     text: { _ in nil }, textWithActualRange: { _ in
                ("测试", NSRange(location: location, length: reportedLength))
            })
        }
        #expect(read(at: 0) == "测试")
        #expect(read(at: 1) == nil)
        #expect(read(at: 0, reportedLength: 3) == nil)
    }

    @Test func checksForMarkedTextOnlyBeforeReading() {
        func read(markedBefore: NSRange) -> String? {
            var marked = markedBefore
            return ReturnFieldLearning.read(isCurrent: { true }, selection: { NSRange() },
                                            markedRange: { marked },
                                            text: { _ in
                marked = NSRange(location: 1, length: 1)
                return "测试"
            }, textWithActualRange: { _ in nil })
        }
        #expect(read(markedBefore: NSRange(location: NSNotFound, length: 0)) == "测试")
        #expect(read(markedBefore: NSRange(location: 1, length: 1)) == nil)
    }

    @Test func usesTheAvailablePrefixWhenTheHostRejectsTheFixedRange() {
        let text = "我来就错了"
        let caret = NSRange(location: text.utf16.count, length: 0)
        for response in [nil, (text: "", range: NSRange())] {
            let captured = ReturnFieldLearning.read(isCurrent: { true }, selection: { caret },
                                                   markedRange: { NSRange(location: NSNotFound, length: 0) },
                                                   text: { range in
                if range.length == 1_024 { return nil }
                #expect(range == NSRange(location: 0, length: caret.location))
                return text
            }, textWithActualRange: { _ in response })
            #expect(captured == text)
        }
    }
}
