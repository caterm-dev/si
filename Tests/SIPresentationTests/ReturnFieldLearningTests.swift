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

    @Test func readsTheWholeUTF16FieldAndRejectsPartialOrStaleReads() {
        let field = "前面🙂后面"
        let length = field.utf16.count
        let cursor = NSRange(location: 2, length: 0)
        let unmarked = NSRange(location: NSNotFound, length: NSNotFound)
        var current = true
        func read(text: (NSRange) -> String?) -> String? {
            ReturnFieldLearning.read(isCurrent: { current }, selection: { cursor }, markedRange: { unmarked },
                                     length: { length }, text: text)
        }
        let captured = read { range in
            #expect(range == NSRange(location: 0, length: length))
            return field
        }
        #expect(captured == field)
        #expect(read { _ in "前面" } == nil)
        let stale = read { _ in
            current = false
            return field
        }
        #expect(stale == nil)
    }
}
