import Foundation
import Testing
@testable import SIPresentation

struct CandidatePlacementTests {
    private let primary = CandidatePlacement.Screen(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                                    visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875))

    @Test func freshInlineCaretReplacesAPreviouslyCachedDocumentFallback() {
        var anchor = CandidateAnchor()
        let marked = NSRange(location: 20, length: 2)
        let displaced = CGRect(x: 8, y: 8, width: 1, height: 20)
        let first = anchor.resolve(cursorUTF16Offset: 2, markedRange: marked, screens: [primary],
                                   queryRange: { _ in displaced }) { _ in .zero }
        #expect(first == displaced)
        let expected = CGRect(x: 1324, y: 640, width: 1, height: 20)
        let fresh = anchor.resolve(cursorUTF16Offset: 2, markedRange: marked, screens: [primary],
                                   queryRange: { _ in displaced }) { _ in expected }
        #expect(fresh == expected)
        let pending = anchor.resolve(cursorUTF16Offset: 2, markedRange: marked, screens: [primary],
                                     queryRange: { _ in displaced }) { _ in .zero }
        #expect(pending == expected)
    }

    @Test func originNeedsIndependentDocumentCorroborationRatherThanAFrameAtScreenZero() {
        var anchor = CandidateAnchor()
        let origin = CGRect(x: 0, y: 0, width: 1, height: 20)
        let marked = NSRange(location: 20, length: 2)
        let missing = anchor.resolve(cursorUTF16Offset: 2, markedRange: marked, screens: [primary],
                                     queryRange: { _ in .zero }) { _ in origin }
        #expect(missing == nil)
        let confirmed = anchor.resolve(cursorUTF16Offset: 2, markedRange: marked, screens: [primary],
                                       queryRange: { _ in origin }) { _ in origin }
        #expect(confirmed == origin)
    }

    @Test func documentFallbackMustCorrespondToTheRequestedInsertionRange() {
        let rect = CGRect(x: 100, y: 500, width: 1, height: 20)
        let requested = NSRange(location: 250, length: 0)
        for actual in [NSRange(location: NSNotFound, length: 0), NSRange(location: 0, length: 10),
                       NSRange(location: Int.max - 2, length: 10)] {
            #expect(CandidateAnchor.documentRect(rect, actualRange: actual, requestedRange: requested).isNull)
        }
        #expect(CandidateAnchor.documentRect(rect, actualRange: requested, requestedRange: requested) == rect)
        #expect(CandidateAnchor.documentRect(rect, actualRange: NSRange(location: 249, length: 2),
                                            requestedRange: requested) == rect)
    }

    @Test func temporaryDocumentFailureCannotMoveAnEstablishedAnchorToTheScreenCorner() {
        var anchor = CandidateAnchor()
        let marked = NSRange(location: 100, length: 4)
        let expected = CGRect(x: 700, y: 600, width: 1, height: 20)
        _ = anchor.resolve(cursorUTF16Offset: 4, markedRange: marked, screens: [primary],
                           queryRange: { _ in expected }) { _ in .zero }
        var fallbackQueries = 0
        for _ in 0..<10 {
            let rect = anchor.resolve(cursorUTF16Offset: 5, markedRange: marked, screens: [primary],
                                      queryRange: { _ in .zero }) { _ in
                fallbackQueries += 1
                return CGRect(x: 0, y: 0, width: 1, height: 20)
            }
            #expect(rect == expected)
        }
        #expect(fallbackQueries > 0)
        let moved = CGRect(x: 720, y: 500, width: 1, height: 20)
        #expect(anchor.resolve(cursorUTF16Offset: 6, markedRange: marked, screens: [primary],
                               queryRange: { _ in moved }) { _ in .zero } == moved)
    }

    @Test func inlineSessionGeometryTakesPriorityOverDisplacedDocumentGeometry() throws {
        var anchor = CandidateAnchor()
        // Document offsets count UTF-16, including text before the current composition.
        let start = "Synthetic 😀 prefix ".utf16.count
        var requestedRanges: [NSRange] = []
        var requestedIndexes: [Int] = []
        let rect = try #require(anchor.resolve(cursorUTF16Offset: 18, markedRange: NSRange(location: start, length: 18),
                                               screens: [primary], queryRange: { range in
            requestedRanges.append(range)
            return CGRect(x: 8, y: 8, width: 0, height: 20)
        }) { index in
            requestedIndexes.append(index)
            return CGRect(x: 1324, y: 640, width: 1, height: 20)
        })
        let frame = try #require(CandidatePlacement.frame(preferredSize: CGSize(width: 610, height: 36),
                                                         anchor: rect, screens: [primary]))
        #expect(requestedRanges.isEmpty)
        #expect(requestedIndexes == [0])
        #expect(rect.minX == 1324)
        #expect(frame.minX == 826) // The wide card stays on screen beside the right-hand input.
        #expect(frame.maxY == rect.minY - 4)
    }

    @Test(arguments: [CGRect.zero, CGRect.null, CGRect.infinite,
                      CGRect(x: 9000, y: 9000, width: 1, height: 20)])
    func unavailableDocumentGeometryFallsBackToInlineStart(invalid: CGRect) {
        var anchor = CandidateAnchor()
        var requested: [Int] = []
        let expected = CGRect(x: 94, y: 800, width: 1, height: 20)
        let rect = anchor.resolve(cursorUTF16Offset: 18, markedRange: NSRange(location: 250, length: 18),
                                  screens: [primary], queryRange: { _ in invalid }) { index in
            requested.append(index)
            return expected
        }
        #expect(rect == expected)
        #expect(requested == [0])
    }

    @Test(arguments: [NSRange(location: NSNotFound, length: NSNotFound), NSRange(location: NSNotFound, length: 0),
                      NSRange(location: 100, length: 0), NSRange(location: 100, length: NSNotFound),
                      NSRange(location: Int.max - 2, length: 5)])
    func unavailableMarkedRangeDoesNotQueryAnUnrelatedDocumentPosition(markedRange: NSRange) {
        var anchor = CandidateAnchor()
        var requestedRanges: [NSRange] = []
        let expected = CGRect(x: 94, y: 800, width: 1, height: 20)
        let rect = anchor.resolve(cursorUTF16Offset: 18, markedRange: markedRange, screens: [primary], queryRange: { range in
            requestedRanges.append(range)
            return CGRect(x: 724, y: 140, width: 1, height: 20)
        }) { _ in expected }
        #expect(requestedRanges.isEmpty)
        #expect(rect == expected)
    }

    @Test func freshDocumentGeometryFollowsReflowAndReplacesTheCompositionCache() {
        var anchor = CandidateAnchor()
        let markedRange = NSRange(location: 250, length: 18)
        for expected in [CGRect(x: 94, y: 800, width: 1, height: 20), CGRect(x: 52, y: 180, width: 1, height: 20)] {
            let rect = anchor.resolve(cursorUTF16Offset: 18, markedRange: markedRange, screens: [primary],
                                      queryRange: { _ in expected }) { _ in .zero }
            #expect(rect == expected)
            let cached = anchor.resolve(cursorUTF16Offset: 18, markedRange: markedRange, screens: [primary],
                                        queryRange: { _ in .zero }) { _ in .zero }
            #expect(cached == expected)
        }
        anchor.reset()
        let cleared = anchor.resolve(cursorUTF16Offset: 18, markedRange: markedRange, screens: [primary],
                                     queryRange: { _ in .zero }) { _ in .zero }
        #expect(cleared == nil)
    }

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
