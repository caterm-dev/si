import Foundation
import Testing
@testable import SIPresentation

struct CandidateGeometryReaderTests {
    private let screen = CandidatePlacement.Screen(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                                   visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875))
    private let insertion = CGRect(x: 420, y: 120, width: 0, height: 20)
    private let placeholder = CGRect(x: 10, y: 850, width: 1, height: 20)

    @Test func verifiedInsertionGeometryOverridesAnOnScreenInlinePlaceholder() throws {
        let selection = NSRange(location: 42, length: 0)
        var inlineReads = 0
        let rect = try #require(CandidateGeometryReader.read(inlineOffset: 0, documentBounds: selection,
            screens: [screen], isCurrent: { true }, documentRectangle: { requested in
                #expect(requested == selection)
                return (insertion, requested)
            }, inlineRectangle: { _ in inlineReads += 1; return placeholder }))
        let anchor = try #require(CandidateAnchor(rect, screens: [screen]))
        #expect(CandidatePlacement.frame(preferredSize: CGSize(width: 480, height: 36), anchor: anchor)?.origin
                == CGPoint(x: 420, y: 84))
        #expect(inlineReads == 0)
    }

    @Test func markedGeometryUsesTheDocumentPositionInsteadOfTheInlineOffset() throws {
        let marked = NSRange(location: 42, length: 8)
        let line = try #require(CandidateAnchor.activeLine(inlineText: "ab👩‍💻c", caretUTF16Offset: 8,
            retainedStart: 0, screens: [screen]) { offset in
                CandidateGeometryReader.read(inlineOffset: offset, documentBounds: marked, screens: [screen],
                    isCurrent: { true }, documentRectangle: { requested in
                        #expect(requested == NSRange(location: 42 + offset, length: 0))
                        return (CGRect(x: 420 + Double(offset) * 8, y: 120, width: 0, height: 20), requested)
                    }, inlineRectangle: { _ in placeholder })
            })
        #expect(line.offset == 0 && line.anchor.rect.minX == 420 && line.anchor.rect.minY == 120)
    }

    @Test func unsupportedOrWrongDocumentGeometryKeepsTheInlineFallback() {
        let marked = NSRange(location: 42, length: 8)
        let responses: [(CGRect, NSRange)?] = [
            nil,
            (.zero, NSRange(location: 46, length: 0)),
            (CGRect(x: 1e-314, y: 2_343_000, width: 1e-314, height: -1), NSRange(location: 46, length: 0)),
            (insertion, NSRange(location: NSNotFound, length: 0)),
            (insertion, NSRange(location: 42, length: 8)),
            (insertion, NSRange(location: 46, length: 5)),
        ]
        for response in responses {
            let rect = CandidateGeometryReader.read(inlineOffset: 4, documentBounds: marked, screens: [screen],
                isCurrent: { true }, documentRectangle: { _ in response }, inlineRectangle: { offset in
                    #expect(offset == 4)
                    return insertion
                })
            #expect(rect == insertion)
        }
    }

    @Test func unavailableDocumentRangesDoNotTriggerGuessedQueries() {
        for bounds in [nil, NSRange(location: NSNotFound, length: 0), NSRange(location: Int.max - 1, length: 8)] {
            let rect = CandidateGeometryReader.read(inlineOffset: 0, documentBounds: bounds, screens: [screen],
                isCurrent: { true }, documentRectangle: { _ in Issue.record("Invalid document query"); return nil },
                inlineRectangle: { _ in insertion })
            #expect(rect == insertion)
        }
    }

    @Test func obsoleteDocumentAndInlineCallsStopBeforeUsingTheirRectangles() {
        for obsoleteDuringDocument in [true, false] {
            var current = true
            var inlineReads = 0
            let rect = CandidateGeometryReader.read(inlineOffset: 0, documentBounds: NSRange(location: 42, length: 0),
                screens: [screen], isCurrent: { current }, documentRectangle: { requested in
                    if obsoleteDuringDocument { current = false }
                    return (.zero, requested)
                }, inlineRectangle: { _ in
                    inlineReads += 1
                    current = false
                    return insertion
                })
            #expect(rect == nil && inlineReads == (obsoleteDuringDocument ? 0 : 1))
        }
    }
}
