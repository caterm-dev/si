import Foundation
import Testing
@testable import SIPresentation

struct CandidatePlacementTests {
    private let primary = CandidatePlacement.Screen(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                                    visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875))

    @Test func aDisplacedHostRectangleCannotMoveThePanelDuringComposition() throws {
        var anchor = CandidateAnchor()
        let start = CGRect(x: 620, y: 300, width: 1, height: 20)
        let displaced = CGRect(x: 1380, y: 810, width: 1, height: 20)
        var queries = 0
        func query(_ rect: CGRect) -> CGRect {
            queries += 1
            return rect
        }
        let first = anchor.resolve(screens: [primary]) { query(start) }
        let later = try #require(anchor.resolve(screens: [primary]) { query(displaced) })
        #expect(first == start)
        #expect(later == start)
        #expect(queries == 1)
        let frame = try #require(CandidatePlacement.frame(preferredSize: CGSize(width: 300, height: 36),
                                                         anchor: later, screens: [primary]))
        #expect(frame.minX == start.minX)
        #expect(frame.maxY == start.minY - 4)

        anchor.reset()
        #expect(anchor.resolve(screens: [primary]) { query(displaced) } == displaced)
        #expect(queries == 2)
    }

    @Test(arguments: [CGRect.zero, CGRect.null, CGRect.infinite,
                      CGRect(x: CGFloat.nan, y: 100, width: 1, height: 20),
                      CGRect(x: 0, y: 0, width: 1, height: 20),
                      CGRect(x: 100, y: 100, width: 900, height: 500),
                      CGRect(x: 9000, y: 9000, width: 1, height: 20)])
    func missingOrInvalidInitialGeometryCanRecoverOnTheNextRefresh(invalid: CGRect) {
        var anchor = CandidateAnchor()
        #expect(anchor.resolve(screens: [primary]) { invalid } == nil)
        let valid = CGRect(x: 400, y: 650, width: 0, height: 20)
        #expect(anchor.resolve(screens: [primary]) { valid } == CGRect(x: 400, y: 650, width: 1, height: 20))
    }

    @Test func aWideRectangleUsesTheDisplayContainingItsLeadingEdge() throws {
        let right = CandidatePlacement.Screen(frame: CGRect(x: 1440, y: 0, width: 1440, height: 900),
                                              visibleFrame: CGRect(x: 1440, y: 0, width: 1440, height: 875))
        let caret = CGRect(x: 1400, y: 650, width: 120, height: 20)
        let frame = try #require(CandidatePlacement.frame(preferredSize: CGSize(width: 300, height: 36),
                                                         anchor: caret, screens: [primary, right]))
        #expect(primary.visibleFrame.contains(frame))
    }

    @Test func bottomAndRightEdgesUseTheSameScreenAndAvoidInputOverlap() throws {
        let caret = CGRect(x: 1430, y: 8, width: 1, height: 22)
        let frame = try #require(CandidatePlacement.frame(preferredSize: CGSize(width: 350, height: 311),
                                                         anchor: caret, screens: [primary]))
        #expect(frame.minX == 1086)
        #expect(frame.minY == caret.maxY + 4)
        #expect(primary.visibleFrame.contains(frame))
        #expect(!frame.intersects(caret))
    }

    @Test func displaysToTheLeftAndAboveUseGlobalAppKitPoints() throws {
        let left = CandidatePlacement.Screen(frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
                                             visibleFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1055))
        let above = CandidatePlacement.Screen(frame: CGRect(x: 0, y: 900, width: 1920, height: 1080),
                                              visibleFrame: CGRect(x: 0, y: 900, width: 1920, height: 1055))
        for caret in [CGRect(x: -500, y: 1000, width: 1, height: 20), CGRect(x: 400, y: 1800, width: 1, height: 20)] {
            let frame = try #require(CandidatePlacement.frame(preferredSize: CGSize(width: 250, height: 311),
                                                             anchor: caret, screens: [primary, left, above]))
            #expect(frame.minX == caret.minX)
            #expect(frame.maxY == caret.minY - 4)
        }
    }

    @Test func disconnectedDisplayInvalidatesCachedCoordinates() {
        let secondary = CandidatePlacement.Screen(frame: CGRect(x: 1440, y: 0, width: 1440, height: 900),
                                                  visibleFrame: CGRect(x: 1440, y: 0, width: 1440, height: 875))
        var anchor = CandidateAnchor()
        _ = anchor.resolve(screens: [primary, secondary]) {
            CGRect(x: 2000, y: 700, width: 1, height: 20)
        }
        let result = anchor.resolve(screens: [primary]) { .zero }
        #expect(result == nil)
    }
}
