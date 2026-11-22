import Foundation
import Testing
@testable import SIPresentation

struct CandidatePlacementTests {
    private let primary = CandidatePlacement.Screen(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                                    visibleFrame: CGRect(x: 0, y: 40, width: 1440, height: 835))
    private let size = CGSize(width: 300, height: 36)

    @Test func onlyInlineAndDocumentStartsAreProbed() {
        for length in [1, 9, 10] {
            #expect(CandidateAnchor.startIndices(marked: NSRange(location: 2373, length: length)) == [0, 2373])
        }
    }

    @Test(arguments: [NSRange(location: 0, length: 9), NSRange(location: NSNotFound, length: 0),
                      NSRange(location: 20, length: 0), NSRange(location: Int.max - 1, length: 7)])
    func onlyTheInlineStartIsProbedWithoutADistinctValidMarkedRange(marked: NSRange) {
        #expect(CandidateAnchor.startIndices(marked: marked) == [0])
    }

    @Test func typingDeletionAndMovingTheCaretReuseTheCompositionStart() throws {
        var marked = MarkedTextState()
        let start = CGRect(x: 370, y: 420, width: 1, height: 20)
        let endOfLine = CGRect(x: 960, y: 400, width: 1, height: 20)
        _ = marked.shouldSend("dang qian", selection: NSRange(location: 9, length: 0))
        let initial = try #require(marked.candidateAnchor(screens: [primary]) {
            CandidateAnchor(start, screens: [primary])
        })
        marked.candidateStartRect = initial.rect

        for (spelling, caret) in [("dang qianx", 10), ("dang qian", 9), ("dang qian", 5)] {
            _ = marked.shouldSend(spelling, selection: NSRange(location: caret, length: 0))
            let anchor = try #require(marked.candidateAnchor(screens: [primary]) {
                Issue.record("Placement should reuse the composition start without querying the host.")
                return CandidateAnchor(endOfLine, screens: [primary])
            })
            #expect(anchor.rect == start)
            #expect(CandidatePlacement.frame(preferredSize: size, anchor: anchor)
                    == CandidatePlacement.frame(preferredSize: size, anchor: initial))
        }

        marked.reset()
        _ = marked.shouldSend("ni", selection: NSRange(location: 2, length: 0))
        let next = marked.candidateAnchor(screens: [primary]) { CandidateAnchor(endOfLine, screens: [primary]) }
        #expect(next?.rect == endOfLine)
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
