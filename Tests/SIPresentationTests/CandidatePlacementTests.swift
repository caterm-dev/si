import Foundation
import Testing
@testable import SIPresentation

struct CandidatePlacementTests {
    private let primary = CandidatePlacement.Screen(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                                    visibleFrame: CGRect(x: 0, y: 40, width: 1440, height: 835))
    private let size = CGSize(width: 300, height: 36)

    @Test func onlyInlineAndDocumentStartsAreProbed() {
        for length in [1, 9, 10] {
            #expect(CandidateAnchor.startIndices(marked: NSRange(location: 2553, length: length)) == [0, 2553])
        }
    }

    @Test(arguments: [NSRange(location: 0, length: 9), NSRange(location: NSNotFound, length: 0),
                      NSRange(location: 20, length: 0), NSRange(location: Int.max - 1, length: 7)])
    func invalidDocumentRangesDoNotBlockInlineGeometry(marked: NSRange) {
        #expect(CandidateAnchor.startIndices(marked: marked) == [0])
    }

    @Test func typingAcrossAWrapDeletionAndCaretMovementKeepTheCompositionStart() throws {
        var state = MarkedTextState()
        let start = CGRect(x: 1076, y: 84, width: 1, height: 16)
        let wrapped = CGRect(x: 480, y: 68, width: 1, height: 16)
        _ = state.shouldSend("d", selection: NSRange(location: 1, length: 0))
        let initial = try #require(state.candidateAnchor(screens: [primary]) {
            CandidateAnchor(start, screens: [primary])
        })
        state.candidateStartRect = initial.rect

        for (spelling, caret) in [("dang qian", 9), ("dang", 4), ("dang", 2), ("dang", 0)] {
            _ = state.shouldSend(spelling, selection: NSRange(location: caret, length: 0))
            let anchor = try #require(state.candidateAnchor(screens: [primary]) {
                Issue.record("An ongoing composition must retain its start instead of following host caret geometry.")
                return CandidateAnchor(wrapped, screens: [primary])
            })
            #expect(anchor.rect == start)
            #expect(CandidatePlacement.frame(preferredSize: size, anchor: anchor)
                    == CandidatePlacement.frame(preferredSize: size, anchor: initial))
        }

        // Full commits, cancellation and client changes reset this state.
        state.reset()
        _ = state.shouldSend("qian", selection: NSRange(location: 4, length: 0))
        let remainder = state.candidateAnchor(screens: [primary]) { CandidateAnchor(wrapped, screens: [primary]) }
        #expect(remainder?.rect == wrapped)
    }

    @Test func successivePrefixCommitsKeepTheOriginalStartUntilCompositionEnds() throws {
        var state = MarkedTextState()
        let start = CGRect(x: 370, y: 420, width: 1, height: 20)
        let nextStart = CGRect(x: 600, y: 400, width: 1, height: 20)
        _ = state.shouldSend("ni hao shi jie", selection: NSRange(location: 14, length: 0))
        state.candidateStartRect = start

        for remainder in ["hao shi jie", "shi jie", "jie"] {
            state.reset(preservingCandidateStart: true)
            #expect(state.text == nil)
            #expect(state.caretUTF16Offset == nil)
            let sendsRemainder = state.shouldSend(remainder, selection: NSRange(location: remainder.utf16.count, length: 0))
            #expect(sendsRemainder)
            let anchor = try #require(state.candidateAnchor(screens: [primary]) {
                Issue.record("Prefix confirmation must not query a new panel start.")
                return CandidateAnchor(nextStart, screens: [primary])
            })
            #expect(anchor.rect == start)
            #expect(CandidatePlacement.frame(preferredSize: size, anchor: anchor)
                    == CGRect(x: 370, y: 384, width: 300, height: 36))
        }

        // Finishing or cancelling the remainder must release the original anchor.
        state.reset()
        #expect(state.candidateStartRect == nil)
        _ = state.shouldSend("xin", selection: NSRange(location: 3, length: 0))
        let next = state.candidateAnchor(screens: [primary]) { CandidateAnchor(nextStart, screens: [primary]) }
        #expect(next?.rect == nextStart)
    }

    @Test func anUnavailableInlineStartUsesOnlyTheDocumentStart() throws {
        var attempts: [Int] = []
        let start = CGRect(x: 370, y: 420, width: 1, height: 20)
        let result = try #require(CandidateAnchor.query(
            indices: CandidateAnchor.startIndices(marked: NSRange(location: 2553, length: 9)), screens: [primary]
        ) { index in
            attempts.append(index)
            return index == 2553 ? start : .zero
        })
        #expect(result.index == 2553)
        #expect(result.anchor.rect == start)
        #expect(attempts == [0, 2553])
    }

    @Test func aCachedStartOnADisconnectedDisplayIsQueriedAgain() throws {
        var state = MarkedTextState()
        state.candidateStartRect = CGRect(x: 2000, y: 700, width: 1, height: 20)
        let start = CGRect(x: 400, y: 650, width: 1, height: 20)
        let anchor = try #require(state.candidateAnchor(screens: [primary]) { CandidateAnchor(start, screens: [primary]) })
        #expect(anchor.rect == start)
    }

    @Test func aSupersededProbeStopsBeforeQueryingAnotherIndex() {
        var attempts: [Int] = []
        let result = CandidateAnchor.query(indices: [0, 2553], screens: [primary]) { index in
            attempts.append(index)
            return nil
        }
        #expect(result == nil)
        #expect(attempts == [0])
    }

    @Test func enoughSpacePlacesTheWindowDirectlyBelowTheCaret() throws {
        let caret = CGRect(x: 620, y: 300, width: 0, height: 20)
        let anchor = try #require(CandidateAnchor(caret, screens: [primary]))
        #expect(anchor.rect.width == 1)
        #expect(CandidatePlacement.frame(preferredSize: size, anchor: anchor)
                == CGRect(x: 620, y: 264, width: 300, height: 36))
    }

    @Test func aLargerWindowFlipsAboveTheCaretWhenItNoLongerFitsBelow() throws {
        let caret = CGRect(x: 500, y: 80, width: 1, height: 22)
        let anchor = try #require(CandidateAnchor(caret, screens: [primary]))
        #expect(CandidatePlacement.frame(preferredSize: size, anchor: anchor)
                == CGRect(x: 500, y: 44, width: 300, height: 36))
        #expect(CandidatePlacement.frame(preferredSize: CGSize(width: 350, height: 311), anchor: anchor)
                == CGRect(x: 500, y: 102, width: 350, height: 311))
    }

    @Test func rightEdgeClampsToTheVisibleFrame() throws {
        let caret = CGRect(x: 1430, y: 300, width: 1, height: 22)
        let anchor = try #require(CandidateAnchor(caret, screens: [primary]))
        #expect(CandidatePlacement.frame(preferredSize: size, anchor: anchor)
                == CGRect(x: 1140, y: 264, width: 300, height: 36))
    }

    @Test func aZeroRectangleUsesTheLastValidLocationBeforeTheMouse() throws {
        #expect(CandidateAnchor(.zero, screens: [primary]) == nil)
        let lastValid = CGRect(x: 400, y: 650, width: 1, height: 20)
        let mouse = CGPoint(x: 300, y: 400)
        let cached = try #require(CandidateAnchor.fallback(lastValid: lastValid, mouseLocation: mouse, screens: [primary]))
        let atMouse = try #require(CandidateAnchor.fallback(lastValid: nil, mouseLocation: mouse, screens: [primary]))
        #expect(CandidatePlacement.frame(preferredSize: size, anchor: cached)
                == CGRect(x: 400, y: 614, width: 300, height: 36))
        #expect(CandidatePlacement.frame(preferredSize: size, anchor: atMouse)
                == CGRect(x: 300, y: 364, width: 300, height: 36))
    }

    @Test(arguments: [CGRect.zero, CGRect.null, CGRect.infinite,
                      CGRect(x: CGFloat.nan, y: 100, width: 1, height: 20),
                      CGRect(x: 100, y: 100, width: 1, height: 0),
                      CGRect(x: 100, y: 100, width: 1, height: -20),
                      CGRect(x: 9000, y: 9000, width: 1, height: 20)])
    func invalidClientRectanglesAreRejected(invalid: CGRect) {
        #expect(CandidateAnchor(invalid, screens: [primary]) == nil)
    }

    @Test func aNonzeroLineRectangleCanStartAtTheGlobalOrigin() {
        #expect(CandidateAnchor(CGRect(x: 0, y: 0, width: 0, height: 20), screens: [primary]) != nil)
    }

    @Test func aWideRectangleUsesTheDisplayContainingItsLeadingEdge() throws {
        let right = CandidatePlacement.Screen(frame: CGRect(x: 1440, y: 0, width: 1440, height: 900),
                                              visibleFrame: CGRect(x: 1440, y: 0, width: 1440, height: 875))
        let caret = CGRect(x: 1400, y: 650, width: 120, height: 20)
        let anchor = try #require(CandidateAnchor(caret, screens: [right, primary]))
        #expect(anchor.screen.frame == primary.frame)
        #expect(CandidatePlacement.frame(preferredSize: size, anchor: anchor)
                == CGRect(x: 1140, y: 614, width: 300, height: 36))
    }

    @Test func displaysToTheLeftAndAboveUseGlobalAppKitPoints() throws {
        let left = CandidatePlacement.Screen(frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
                                             visibleFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1055))
        let above = CandidatePlacement.Screen(frame: CGRect(x: 0, y: 900, width: 1920, height: 1080),
                                              visibleFrame: CGRect(x: 0, y: 900, width: 1920, height: 1055))
        for (caret, screen) in [(CGRect(x: -500, y: 1000, width: 1, height: 20), left),
                               (CGRect(x: 400, y: 1800, width: 1, height: 20), above)] {
            let anchor = try #require(CandidateAnchor(caret, screens: [primary, left, above]))
            #expect(anchor.screen.frame == screen.frame)
            #expect(CandidatePlacement.frame(preferredSize: size, anchor: anchor)
                    == CGRect(x: caret.minX, y: caret.minY - 36, width: 300, height: 36))
        }
    }

    @Test func aDisconnectedDisplayFallsBackToTheMouseOnTheRemainingScreen() throws {
        let lastValid = CGRect(x: 2000, y: 700, width: 1, height: 20)
        let mouse = CGPoint(x: 500, y: 400)
        let anchor = try #require(CandidateAnchor.fallback(lastValid: lastValid, mouseLocation: mouse, screens: [primary]))
        #expect(anchor.rect.origin == mouse)
        #expect(anchor.screen.frame == primary.frame)
        #expect(CandidateAnchor.fallback(lastValid: lastValid, mouseLocation: mouse, screens: []) == nil)
    }
}
