import Foundation
import Testing
@testable import SIPresentation

struct CandidatePlacementTests {
    private let primary = CandidatePlacement.Screen(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                                    visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875))

    @Test func compositionStartAnchorsDirectlyBelowTheInputWithoutRetinaScaling() throws {
        var anchor = CandidateAnchor()
        var requested: [Int] = []
        let rect = try #require(anchor.resolve(cursorUTF16Offset: 18, screens: [primary]) { index in
            requested.append(index)
            return index == 0 ? CGRect(x: 94, y: 800, width: 0, height: 20) : .zero
        })
        let frame = try #require(CandidatePlacement.frame(preferredSize: CGSize(width: 250, height: 311),
                                                         anchor: rect, screens: [primary]))
        #expect(requested == [0])
        #expect(frame.minX == 94)
        #expect(frame.maxY == 796)
        #expect(rect.width == 1)
    }

    @Test func temporaryFailureReusesOnlyThisCompositionsLastValidGeometry() throws {
        var anchor = CandidateAnchor()
        var requested: [Int] = []
        let expected = CGRect(x: 180, y: 700, width: 1, height: 22)
        let first = anchor.resolve(cursorUTF16Offset: 5, screens: [primary]) { index in
            requested.append(index)
            return index == 5 ? expected : .zero
        }
        #expect(first == expected)
        #expect(requested == [0, 5])
        let repeated = anchor.resolve(cursorUTF16Offset: 7, screens: [primary]) { _ in .zero }
        #expect(repeated == expected)
        anchor.reset()
        let afterReset = anchor.resolve(cursorUTF16Offset: 7, screens: [primary]) { _ in .zero }
        #expect(afterReset == nil)
        var otherClient = CandidateAnchor()
        let otherClientResult = otherClient.resolve(cursorUTF16Offset: 7, screens: [primary]) { _ in .zero }
        #expect(otherClientResult == nil)
    }

    @Test func missingAndInvalidCoordinatesNeverInventAScreenCenterAnchor() {
        for invalid in [CGRect.zero, CGRect.null, CGRect.infinite,
                        CGRect(x: CGFloat.nan, y: 100, width: 1, height: 20),
                        CGRect(x: 9000, y: 9000, width: 1, height: 20)] {
            var anchor = CandidateAnchor()
            let result = anchor.resolve(cursorUTF16Offset: 4, screens: [primary]) { _ in invalid }
            #expect(result == nil)
            #expect(CandidatePlacement.frame(preferredSize: CGSize(width: 250, height: 311),
                                             anchor: invalid, screens: [primary]) == nil)
        }
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
        _ = anchor.resolve(cursorUTF16Offset: 1, screens: [primary, secondary]) { _ in
            CGRect(x: 2000, y: 700, width: 1, height: 20)
        }
        let result = anchor.resolve(cursorUTF16Offset: 2, screens: [primary]) { _ in .zero }
        #expect(result == nil)
    }
}
