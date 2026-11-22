import Foundation
import Testing
@testable import SIPresentation

struct CandidatePlacementTests {
    private let primary = CandidatePlacement.Screen(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                                    visibleFrame: CGRect(x: 0, y: 40, width: 1440, height: 835))
    private let size = CGSize(width: 300, height: 36)

    @Test func inlineCaretPrecedesTheDocumentRanges() {
        let marked = NSRange(location: 2373, length: 10)
        for selected in [NSRange(location: 2373, length: 10), NSRange(location: 0, length: 10)] {
            #expect(CandidateAnchor.queryIndices(inlineText: "dang qianx", caretUTF16Offset: 10,
                                                 marked: marked, selected: selected) == [10, 9, 2373, 2383, 0])
        }
    }

    @Test func aCompositionStartingAtZeroCanStillQueryTheCaret() {
        let range = NSRange(location: 0, length: 9)
        #expect(CandidateAnchor.queryIndices(inlineText: "dang qian", caretUTF16Offset: 9,
                                             marked: range, selected: range) == [9, 8, 0])
    }

    @Test func theLastCharacterFallbackDoesNotSplitAGrapheme() {
        let missing = NSRange(location: NSNotFound, length: 0)
        #expect(CandidateAnchor.queryIndices(inlineText: "a👩‍💻", caretUTF16Offset: 6,
                                             marked: missing, selected: missing) == [6, 1, 0])
    }

    @Test func interiorCaretUsesTheSentOffsetBeforeCompatibilityProbes() {
        var state = MarkedTextState()
        _ = state.shouldSend("dang qian", selection: NSRange(location: 5, length: 0))
        let caret = state.caretUTF16Offset
        #expect(caret == 5)
        #expect(CandidateAnchor.queryIndices(inlineText: "dang qian", caretUTF16Offset: caret ?? 0,
                                             marked: NSRange(location: 21, length: 9),
                                             selected: NSRange(location: 26, length: 0)) == [5, 21, 30, 26, 0])
    }

    @Test func missingAndOverflowingOffsetsAreSkipped() {
        let missing = NSRange(location: NSNotFound, length: 0)
        #expect(CandidateAnchor.queryIndices(inlineText: "a", caretUTF16Offset: 1,
                                             marked: missing, selected: missing) == [1, 0])
        #expect(CandidateAnchor.queryIndices(inlineText: "a", caretUTF16Offset: 1,
                                             marked: missing, selected: NSRange(location: 7, length: 0)) == [1, 7, 0])
        #expect(CandidateAnchor.queryIndices(inlineText: "a", caretUTF16Offset: 1,
                                             marked: NSRange(location: Int.max - 1, length: 7),
                                             selected: missing) == [1, Int.max - 1, 0])
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
