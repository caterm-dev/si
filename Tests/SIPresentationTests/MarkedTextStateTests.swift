import Foundation
import Testing
import SICore
@testable import SIPresentation

struct MarkedTextStateTests {
    @Test func candidateDeliveriesDoNotResendTheUnchangedHostComposition() throws {
        var session = InputSession(candidateGeneration: .deferred)
        session.configure(languages: [.simplifiedChinese])
        session.append("jintjiushi")
        let request = try #require(session.pendingCandidateRequest)
        var marked = MarkedTextState()
        var sends = 0
        func updateHost() {
            if marked.shouldSend(session.buffer, selection: NSRange(location: session.cursorUTF16Offset, length: 0)) {
                sends += 1
            }
        }
        updateHost()
        let previewAccepted = session.accept(request.generatePreview())
        #expect(previewAccepted)
        updateHost()
        let finalAccepted = session.accept(request.generate())
        #expect(finalAccepted)
        updateHost()
        #expect(sends == 1)
        session.append("a")
        updateHost()
        #expect(sends == 2)
        session.moveCursor(by: -1)
        updateHost()
        #expect(sends == 3)
    }

    @Test func resetAndCancellationStillSendTheRequiredHostUpdate() {
        var state = MarkedTextState()
        let end = NSRange(location: 2, length: 0)
        let first = state.shouldSend("ni", selection: end)
        let repeated = state.shouldSend("ni", selection: end)
        let cancelled = state.shouldSend("", selection: NSRange(location: 0, length: 0))
        #expect(first && !repeated && cancelled)
        state.reset()
        let restarted = state.shouldSend("ni", selection: end)
        #expect(restarted)
        state.reset()
        let newClient = state.shouldSend("ni", selection: end)
        #expect(newClient)
    }

    @Test func canonicallyEqualSpellingStillPreservesExactBytesAndUTF16Selection() {
        var state = MarkedTextState()
        let selection = NSRange(location: 1, length: 0)
        let first = state.shouldSend("é", selection: selection)
        let changedBytes = state.shouldSend("e\u{301}", selection: selection)
        let repeated = state.shouldSend("e\u{301}", selection: selection)
        let movedCaret = state.shouldSend("e\u{301}", selection: NSRange(location: 2, length: 0))
        #expect(first && changedBytes && !repeated && movedCaret)
    }
}
