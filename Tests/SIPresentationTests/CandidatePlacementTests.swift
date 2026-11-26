import Foundation
import Testing
@testable import SIPresentation

struct CandidatePlacementTests {
    private let primary = CandidatePlacement.Screen(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                                    visibleFrame: CGRect(x: 0, y: 40, width: 1440, height: 835))
    private let size = CGSize(width: 300, height: 36)

    @Test func sameLineTypingDeletionAndCaretMovementCannotReplaceTheStart() throws {
        var state = MarkedTextState()
        let start = CGRect(x: 568, y: 53, width: 1, height: 18)
        state.captureCandidateStart(start, screens: [primary])
        for (spelling, caret) in [("d", 1), ("dang qian", 9), ("dang", 4), ("dang", 2), ("dang", 0)] {
            _ = state.shouldSend(spelling, selection: NSRange(location: caret, length: 0))
            state.captureCandidateStart(CGRect(x: 678, y: 300, width: 1, height: 18), screens: [primary])
            let anchor = try #require(state.candidateStart)
            #expect(anchor.rect == start)
            #expect(CandidatePlacement.frame(preferredSize: size, anchor: anchor)
                    == CGRect(x: 568, y: 17, width: 300, height: 36))
        }
    }

    @Test func wrappingAndDeletingBackFollowLineStartsWithoutFollowingTheCaret() throws {
        var state = MarkedTextState()
        let start = CGRect(x: 1000, y: 400, width: 1, height: 18)
        state.captureCandidateStart(start, screens: [primary])
        for (count, expectedOffset, x, y) in [(2, 0, 1000.0, 400.0), (4, 3, 100.0, 380.0),
                                             (5, 3, 100.0, 380.0), (8, 7, 100.0, 360.0),
                                             (5, 3, 100.0, 380.0), (2, 0, 1000.0, 400.0)] {
            let text = String(repeating: "a", count: count)
            _ = state.shouldSend(text, selection: NSRange(location: count, length: 0))
            let line = try #require(CandidateAnchor.activeLine(inlineText: text, caretUTF16Offset: count,
                retainedStart: state.candidateLineStartUTF16Offset, screens: [primary]) { index in
                if index < 3 { return CGRect(x: 1000 + Double(index) * 8, y: 400, width: 1, height: 18) }
                let row = 1 + (index - 3) / 4
                return CGRect(x: 100 + Double((index - 3) % 4) * 8, y: 400 - Double(row) * 20, width: 1, height: 18)
            })
            state.updateCandidateLine(offset: line.offset, anchor: line.anchor)
            #expect(state.candidateLineStartUTF16Offset == expectedOffset)
            #expect(state.candidateStart?.rect.origin == CGPoint(x: x, y: y))
        }
    }

    @Test func aGrowingFieldCanWrapWhileTheCaretKeepsItsOldScreenHeight() throws {
        var state = MarkedTextState()
        state.captureCandidateStart(CGRect(x: 1000, y: 400, width: 1, height: 18), screens: [primary])
        let line = try #require(CandidateAnchor.activeLine(inlineText: "abcd", caretUTF16Offset: 4,
            retainedStart: 0, screens: [primary]) { index in
            CGRect(x: index < 3 ? 1000 + Double(index) * 8 : 100 + Double(index - 3) * 8,
                   y: index < 3 ? 420 : 400, width: 1, height: 18)
        })
        state.updateCandidateLine(offset: line.offset, anchor: line.anchor)
        #expect(line.offset == 3)
        #expect(state.candidateStart?.rect.origin == CGPoint(x: 100, y: 400))
    }

    @Test func overlappingRectsAndMissingIntermediateProbesDoNotKeepThePreviousLine() throws {
        var state = MarkedTextState()
        let previous = CGRect(x: 1047, y: 78, width: 1, height: 14)
        let wrapped = CGRect(x: 587, y: 84, width: 1, height: 16)
        state.captureCandidateStart(previous, screens: [primary])

        let line = try #require(CandidateAnchor.activeLine(inlineText: "he j", caretUTF16Offset: 4,
            retainedStart: state.candidateLineStartUTF16Offset, screens: [primary]) { index in
            switch index {
            case 0: previous
            case 3: wrapped
            default: .zero
            }
        })
        state.updateCandidateLine(offset: line.offset, anchor: line.anchor)
        #expect(line.offset == 3)
        #expect(state.candidateStart?.rect == wrapped)
        #expect(CandidatePlacement.frame(preferredSize: size, anchor: line.anchor)
                == CGRect(x: 587, y: 48, width: 300, height: 36))

        let continued = try #require(CandidateAnchor.activeLine(inlineText: "he ji su", caretUTF16Offset: 8,
            retainedStart: state.candidateLineStartUTF16Offset, screens: [primary]) { index in
            switch index {
            case 3: wrapped
            case 7: CGRect(x: 605, y: 84, width: 1, height: 16)
            default: .zero
            }
        })
        #expect(continued.offset == 3 && continued.anchor.rect == wrapped)
    }

    @Test func rightToLeftTextCanMoveLeftWithinTheSameLine() throws {
        let start = CGRect(x: 400, y: 300, width: 1, height: 20)
        let caret = CGRect(x: 360, y: 300, width: 1, height: 20)
        let line = try #require(CandidateAnchor.activeLine(inlineText: "אב", caretUTF16Offset: 2,
            retainedStart: 0, screens: [primary]) { index in
            index == 0 ? start : caret
        })
        #expect(line.offset == 0 && line.anchor.rect == start)
    }

    @Test func visualWrappingWithOverlappingHeightsAndSparseGeometryFindsTheNewLine() throws {
        var state = MarkedTextState()
        let initial = CGRect(x: 1047, y: 78, width: 1, height: 14)
        state.captureCandidateStart(initial, screens: [primary])
        let second = CGRect(x: 587, y: 84, width: 1, height: 16)
        var attempts: [Int] = []
        let line = try #require(CandidateAnchor.activeLine(inlineText: "abc_12defg", caretUTF16Offset: 10,
            retainedStart: 0, screens: [primary]) { index in
            attempts.append(index)
            switch index {
            case 0: return initial
            case 3: return second
            case 7: return CGRect(x: 605, y: 84, width: 1, height: 16)
            default: return .zero
            }
        })
        state.updateCandidateLine(offset: line.offset, anchor: line.anchor)
        #expect(line.offset == 3 && state.candidateStart?.rect == second)
        #expect(attempts.count <= 32 && Set(attempts).count == attempts.count)
    }

    @Test func deletingBackToTheFirstVisualLineWorksEvenWithOverlappingHeights() throws {
        let line = try #require(CandidateAnchor.activeLine(inlineText: "abcdef", caretUTF16Offset: 6,
            retainedStart: 3, screens: [primary]) { index in
            CGRect(x: 1047 + Double(index) * 8, y: 78, width: 1, height: 14)
        })
        #expect(line.offset == 0 && line.anchor.rect.minX == 1047)
    }

    @Test func documentGeometryUsesExactValidatedUTF16Positions() throws {
        let marked = NSRange(location: 2699, length: 8)
        let range = try #require(CandidateAnchor.documentRange(inlineOffset: 6, inlineUTF16Count: 8, marked: marked))
        #expect(range == NSRange(location: 2705, length: 0))
        #expect(CandidateAnchor.acceptsDocumentGeometry(actual: range, requested: range, marked: marked))
        #expect(!CandidateAnchor.acceptsDocumentGeometry(actual: marked, requested: range, marked: marked))
        #expect(!CandidateAnchor.acceptsDocumentGeometry(actual: NSRange(location: 2705, length: 3),
                                                        requested: range, marked: marked))
        #expect(CandidateAnchor.documentRange(inlineOffset: 6, inlineUTF16Count: 7, marked: marked) == nil)
        #expect(CandidateAnchor.documentRange(inlineOffset: 9, inlineUTF16Count: 8, marked: marked) == nil)
        #expect(CandidateAnchor.documentRange(inlineOffset: 1, inlineUTF16Count: 8,
                                             marked: NSRange(location: Int.max - 1, length: 8)) == nil)
    }

    @Test func sameLineCaretGeometryAndSmallHeightDifferencesDoNotMoveThePanel() throws {
        var state = MarkedTextState()
        let start = CGRect(x: 568, y: 53, width: 1, height: 18)
        state.captureCandidateStart(start, screens: [primary])
        for x in [600.0, 700.0, 800.0] {
            let line = try #require(CandidateAnchor.activeLine(inlineText: "abc", caretUTF16Offset: 3,
                retainedStart: 0, screens: [primary]) { _ in CGRect(x: x, y: 57, width: 1, height: 19) })
            state.updateCandidateLine(offset: line.offset, anchor: line.anchor)
            #expect(state.candidateStart?.rect == start)
        }
    }

    @Test func missingEndGeometryUsesTheLastWholeGraphemeAndKeepsUTF16Offsets() throws {
        var attempts: [Int] = []
        let line = try #require(CandidateAnchor.activeLine(inlineText: "a👩‍💻bc", caretUTF16Offset: 8,
            retainedStart: 0, screens: [primary]) { index in
            attempts.append(index)
            if index == 8 { return .zero }
            return CGRect(x: 100 + Double(index) * 8, y: index < 6 ? 400 : 380, width: 1, height: 18)
        })
        #expect(line.offset == 6)
        #expect(attempts.prefix(2).elementsEqual([8, 7]))
        #expect(attempts.allSatisfy { [0, 1, 6, 7, 8].contains($0) })
    }

    @Test func anObsoleteOrUnavailableLineProbeKeepsTheAnchor() {
        var state = MarkedTextState()
        let start = CGRect(x: 568, y: 53, width: 1, height: 18)
        state.captureCandidateStart(start, screens: [primary])
        var attempts: [Int] = []
        let obsolete = CandidateAnchor.activeLine(inlineText: "abcdef", caretUTF16Offset: 6,
            retainedStart: 0, screens: [primary]) { index in
            attempts.append(index)
            return nil
        }
        #expect(obsolete == nil && attempts == [6])
        let unavailable = CandidateAnchor.activeLine(inlineText: "abcdef", caretUTF16Offset: 6,
            retainedStart: 0, screens: [primary]) { _ in .zero }
        #expect(unavailable == nil && state.candidateStart?.rect == start)

        attempts.removeAll()
        let obsoleteDuringSearch = CandidateAnchor.activeLine(inlineText: "abcd", caretUTF16Offset: 4,
            retainedStart: 0, screens: [primary]) { index in
            attempts.append(index)
            return switch index {
            case 4: CGRect(x: 100, y: 380, width: 1, height: 20)
            case 0: CGRect(x: 950, y: 400, width: 1, height: 20)
            default: nil
            }
        }
        #expect(obsoleteDuringSearch == nil && attempts == [4, 0, 2])
    }

    @Test func prefixRemaindersKeepTheStartAndANewCompositionCapturesANewStart() throws {
        var state = MarkedTextState()
        let start = CGRect(x: 370, y: 420, width: 1, height: 20)
        let nextStart = CGRect(x: 600, y: 400, width: 1, height: 20)
        state.captureCandidateStart(start, screens: [primary])
        _ = state.shouldSend("ni hao shi jie", selection: NSRange(location: 14, length: 0))

        for remainder in ["hao shi jie", "shi jie", "jie"] {
            state.reset(preservingCandidateStart: true)
            #expect(state.text == nil && state.caretUTF16Offset == nil)
            #expect(state.didCaptureCandidateStart)
            _ = state.shouldSend(remainder, selection: NSRange(location: remainder.utf16.count, length: 0))
            state.captureCandidateStart(nextStart, screens: [primary])
            #expect(state.candidateStart?.rect == start)
        }

        state.reset()
        #expect(state.candidateStart == nil && !state.didCaptureCandidateStart)
        state.captureCandidateStart(nextStart, screens: [primary])
        #expect(state.candidateStart?.rect == nextStart)
    }

    @Test func unavailableInitialGeometryIsNeverReplacedByALaterCaret() {
        var state = MarkedTextState()
        state.captureCandidateStart(.zero, screens: [primary])
        #expect(state.didCaptureCandidateStart && state.candidateStart == nil)
        state.reset(preservingCandidateStart: true)
        state.captureCandidateStart(CGRect(x: 900, y: 200, width: 1, height: 20), screens: [primary])
        #expect(state.didCaptureCandidateStart && state.candidateStart == nil)
    }

    @Test func aWrappedPrefixRemainderRebasesItsLineOffsetBeforeMoreTyping() throws {
        var state = MarkedTextState()
        state.captureCandidateStart(CGRect(x: 1000, y: 400, width: 1, height: 18), screens: [primary])
        let wrapped = try #require(CandidateAnchor(CGRect(x: 100, y: 380, width: 1, height: 18), screens: [primary]))
        state.updateCandidateLine(offset: 7, anchor: wrapped)
        state.reset(preservingCandidateStart: true)
        #expect(state.candidateLineStartUTF16Offset == 0 && state.candidateStart?.rect == wrapped.rect)
        let line = try #require(CandidateAnchor.activeLine(inlineText: "abcde", caretUTF16Offset: 5,
            retainedStart: state.candidateLineStartUTF16Offset, screens: [primary]) { index in
            CGRect(x: 100 + Double(index % 4) * 8, y: index < 4 ? 380 : 360, width: 1, height: 18)
        })
        state.updateCandidateLine(offset: line.offset, anchor: line.anchor)
        #expect(state.candidateLineStartUTF16Offset == 4)
        #expect(state.candidateStart?.rect.origin == CGPoint(x: 100, y: 360))
    }

    @Test func screenChangesDoNotRecalculateTheCapturedStart() throws {
        var state = MarkedTextState()
        let removed = CandidatePlacement.Screen(frame: CGRect(x: 1440, y: 0, width: 1440, height: 900),
                                                visibleFrame: CGRect(x: 1440, y: 40, width: 1440, height: 835))
        let start = CGRect(x: 2000, y: 700, width: 1, height: 20)
        state.captureCandidateStart(start, screens: [primary, removed])
        state.captureCandidateStart(CGRect(x: 400, y: 650, width: 1, height: 20), screens: [primary])
        let anchor = try #require(state.candidateStart)
        #expect(anchor.rect == start && anchor.screen.frame == removed.frame)
    }

    @Test func resizingAtScreenEdgesKeepsTheSameTopLeftBelowTheStart() throws {
        let anchor = try #require(CandidateAnchor(CGRect(x: 1430, y: 80, width: 1, height: 22), screens: [primary]))
        for size in [size, CGSize(width: 650, height: 36), CGSize(width: 650, height: 311)] {
            let frame = try #require(CandidatePlacement.frame(preferredSize: size, anchor: anchor))
            #expect(frame.minX == 1430 && frame.maxY == 80)
            #expect(frame.width == 10 && frame.height == size.height)
        }
    }

    @Test(arguments: [CGRect.zero, CGRect.null, CGRect.infinite,
                      CGRect(x: CGFloat.nan, y: 100, width: 1, height: 20),
                      CGRect(x: 100, y: 100, width: 1, height: 0),
                      CGRect(x: 100, y: 100, width: 1, height: -20),
                      CGRect(x: 9000, y: 9000, width: 1, height: 20)])
    func invalidInitialRectanglesAreRejected(invalid: CGRect) {
        #expect(CandidateAnchor(invalid, screens: [primary]) == nil)
    }

    @Test func zeroWidthAndGlobalOriginAreValid() throws {
        let anchor = try #require(CandidateAnchor(CGRect(x: 0, y: 0, width: 0, height: 20), screens: [primary]))
        #expect(anchor.rect.width == 1)
    }

    @Test func displaysToTheLeftAndAboveUseGlobalAppKitPoints() throws {
        let left = CandidatePlacement.Screen(frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
                                             visibleFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1055))
        let above = CandidatePlacement.Screen(frame: CGRect(x: 0, y: 900, width: 1920, height: 1080),
                                              visibleFrame: CGRect(x: 0, y: 900, width: 1920, height: 1055))
        for (rect, screen) in [(CGRect(x: -500, y: 1000, width: 1, height: 20), left),
                              (CGRect(x: 400, y: 1800, width: 1, height: 20), above)] {
            let anchor = try #require(CandidateAnchor(rect, screens: [primary, left, above]))
            #expect(anchor.screen.frame == screen.frame)
            #expect(CandidatePlacement.frame(preferredSize: size, anchor: anchor)
                    == CGRect(x: rect.minX, y: rect.minY - 36, width: 300, height: 36))
        }
    }
}
