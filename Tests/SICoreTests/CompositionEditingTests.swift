import Testing
@testable import SICore

struct CompositionEditingTests {
    @Test func separatelyInsertedScalarsCanJoinWithoutInvalidatingTheCaret() {
        for fragments in [["a", "\u{301}", "b"], ["👩", "🏽", "\u{200D}", "💻", "b"], ["🇺", "🇸", "b"]] {
            var session = InputSession()
            for fragment in fragments {
                session.append(fragment)
                #expect(session.cursor == session.buffer.count)
                #expect(session.cursorUTF16Offset == session.buffer.utf16.count)
            }
            session.deleteBackward()
            #expect(session.buffer.count == 1)
            session.deleteBackward()
            #expect(session.buffer.isEmpty)
        }
    }

    @Test func insertionAtCaretRefreshesPinyinAndLiteralCommit() {
        var session = InputSession()
        session.append("niho")
        session.moveCursor(by: -1)
        session.append("a")
        #expect(session.buffer == "nihao")
        #expect(session.cursor == 4)
        #expect(session.candidates.contains { $0.text == "你好" })
        #expect(session.commit() == "nihao")
        #expect(session.cursor == 0)
        #expect(session.candidates.isEmpty)
    }

    @Test func backwardAndForwardDeletionUseTheCaret() {
        var session = InputSession()
        session.append("nixhao")
        session.moveToStart()
        session.moveCursor(by: 2)
        session.deleteForward()
        #expect(session.buffer == "nihao")
        #expect(session.cursor == 2)
        session.deleteBackward()
        #expect(session.buffer == "nhao")
        #expect(session.cursor == 1)
        session.moveToStart()
        session.deleteBackward()
        #expect(session.buffer == "nhao")
        session.moveToEnd()
        session.deleteForward()
        #expect(session.buffer == "nhao")
    }

    @Test func extendedGraphemesRemainWholeAndMarkedRangeUsesUTF16() {
        var session = InputSession()
        let emoji = "👩🏽‍💻"
        session.append("a\(emoji)b")
        session.moveCursor(by: -1)
        #expect(session.cursor == 2)
        #expect(session.cursorUTF16Offset == 1 + emoji.utf16.count)
        session.deleteBackward()
        #expect(session.buffer == "ab")
        #expect(session.cursor == 1)
        #expect(session.cursorUTF16Offset == 1)
        session.deleteForward()
        #expect(session.buffer == "a")
        session.deleteBackward()
        #expect(session.buffer.isEmpty)
        #expect(session.cursor == 0)
        #expect(session.cursorUTF16Offset == 0)
    }

    @Test func caretBoundsHandleLargeOffsetsWithoutChangingCandidates() {
        var session = InputSession()
        session.append("shi")
        let before = session.candidates
        session.moveCursor(by: .min)
        #expect(session.cursor == 0)
        session.moveCursor(by: .max)
        #expect(session.cursor == session.buffer.count)
        #expect(session.candidates == before)
    }

    @Test func configurationChangesPreserveEditedBufferAndCaret() {
        var session = InputSession()
        session.append("nihao")
        session.moveCursor(by: -2)
        session.configure(languages: [.english])
        #expect(session.buffer == "nihao")
        #expect(session.cursor == 3)
        #expect(session.candidates.last?.text == "nihao")
        session.reset()
        #expect(session.cursor == 0)
    }
}
